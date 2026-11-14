#![cfg(feature = "tokio")]

//! The list's two calls over a tokio transport: read a view and follow it (agent service v2,
//! the design doc, "The list's clients", rule 3). There is no third call.
//!
//! - [`open`] takes the two halves of a fresh connection and sends the upgrade naming `list` as
//!   its first request. A daemon that answers it as an old daemon does (method not found, or
//!   `list` not in its `acpmux.v2`) hands the transport back as [`Opened::Fallback`], and the
//!   caller runs its v1 path whole. No caller reads the daemon's config to choose.
//! - [`ListConnection::read`] reads a window of a view, a walk of a view by page, or rows by key.
//!   A walk asks for its next page only when the caller has taken the last, so it holds at most
//!   one page it has not handed out, and credit follows what the caller took.
//! - [`ListConnection::follow`] is a mirror of a view with held and wanted keys, giving
//!   [`Change`]s; [`Following::reconnect`] resumes it on a new transport.
//! - [`ListConnection::v1_rows`] gives rows as v1 gave them, through [`crate::v1_row`] and
//!   nothing else: the origin's state from the `origin` records the connection saw, the parent
//!   from the rows given, or read by key when it is not among them. A parent that is missing or
//!   unknown gives no `spawnedBy`.

use crate::wire::{
    Anchor, Cursor, ListFilter, ListKey, ListView, MAX_PAGE_BYTES, OriginState, Page, PageKey,
    Position, Sub,
};
use crate::{Change, Client};
use acpmux_list_types::Summary;
use serde_json::Value;
use std::collections::{HashMap, HashSet, VecDeque};
use std::io;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Keys a `page` may ask for at once (the design doc, "A row by its key").
pub const KEYS_PER_PAGE: usize = 100;

/// Rows of a walk's first page, its window. Later pages are cut by the hub's row and byte
/// bounds.
const WALK_WINDOW_ROWS: u16 = 100;

/// What [`open`] gives: a list connection, or the transport back for the v1 path.
pub enum Opened<R, W> {
    List(Box<ListConnection<R, W>>),
    /// The daemon answered the upgrade as an old daemon does. `bytes` are bytes it sent after
    /// that answer, already read.
    Fallback {
        reader: R,
        writer: W,
        bytes: Vec<u8>,
    },
}

/// What one read asks for.
#[derive(Clone, Debug)]
pub enum Read {
    /// The newest `rows` of a view.
    Window { view: ListView, filter: Option<ListFilter>, rows: u16 },
    /// A view from its head, page by page.
    Walk { view: ListView, filter: Option<ListFilter> },
    /// Rows by key, [`KEYS_PER_PAGE`] a request, in any view. A key's activity time is not part
    /// of its identity: `0` reads the row whatever its time.
    Keys(Vec<ListKey>),
}

/// One page of a read.
#[derive(Clone, Debug, Default)]
pub struct Rows {
    pub rows: Vec<Summary>,
    /// Keys of this machine's chats that do not exist.
    pub missing: Vec<ListKey>,
    /// Keys of another origin's chats that nothing here holds: not a deletion.
    pub unknown: Vec<ListKey>,
}

/// A connection upgraded to the list surface.
pub struct ListConnection<R, W> {
    client: Client<Summary>,
    reader: R,
    writer: W,
    /// Bytes read from the transport that the client has not taken yet.
    pending: Vec<u8>,
    origins: HashMap<String, OriginState>,
    next_sid: u64,
    /// Pages a read received and has not handed out, and the most at once.
    unhanded: usize,
    unhanded_peak: usize,
    /// Page requests sent by reads (a window counts as one), and bytes received.
    pages_asked: u64,
    bytes_received: u64,
}

/// Sends the upgrade naming `list` on a fresh connection and reads its answer.
pub async fn open<R, W>(reader: R, writer: W) -> io::Result<Opened<R, W>>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut connection = ListConnection {
        client: Client::new(["list"]),
        reader,
        writer,
        pending: Vec::new(),
        origins: HashMap::new(),
        next_sid: 1,
        unhanded: 0,
        unhanded_peak: 0,
        pages_asked: 0,
        bytes_received: 0,
    };
    match connection.upgrade().await? {
        None => Ok(Opened::List(Box::new(connection))),
        Some(bytes) => {
            Ok(Opened::Fallback { reader: connection.reader, writer: connection.writer, bytes })
        }
    }
}

fn protocol(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

fn row_identity(origin: &str, chat_id: &str) -> (String, String) {
    (origin.to_owned(), chat_id.to_owned())
}

impl<R, W> ListConnection<R, W>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    /// Sends the upgrade and reads up to its answer. `Some(bytes)` is the old daemon's answer,
    /// with the bytes read after it.
    async fn upgrade(&mut self) -> io::Result<Option<Vec<u8>>> {
        self.client.connected();
        self.flush().await?;
        let mut buf = [0_u8; 16 * 1024];
        loop {
            let n = self.reader.read(&mut buf).await?;
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "the daemon closed the connection before it answered the upgrade",
                ));
            }
            self.bytes_received = self.bytes_received.saturating_add(n as u64);
            let bytes = buf.get(..n).unwrap_or_default();
            let used = self.client.received(bytes);
            match self.client.next_change() {
                Some(Change::Fallback(rest)) => return Ok(Some(rest)),
                Some(Change::Error { code, .. }) => {
                    return Err(protocol(format!("the daemon's upgrade answer: {code}")));
                }
                Some(_) => return Err(protocol("a change before the upgrade was answered")),
                None => {}
            }
            // An accepted upgrade queues the client's hello.
            if let Some(hello) = self.client.take_send() {
                self.writer.write_all(&hello).await?;
                self.flush().await?;
                self.pending.extend_from_slice(bytes.get(used..).unwrap_or_default());
                return Ok(None);
            }
        }
    }

    async fn flush(&mut self) -> io::Result<()> {
        let mut wrote = false;
        while let Some(bytes) = self.client.take_send() {
            self.writer.write_all(&bytes).await?;
            wrote = true;
        }
        if wrote {
            self.writer.flush().await?;
        }
        Ok(())
    }

    /// The next change of any subscription on this connection, reading the transport as needed.
    /// Origin records are kept as they pass.
    async fn next_change(&mut self) -> io::Result<Change<Summary>> {
        let mut buf = [0_u8; 16 * 1024];
        loop {
            self.flush().await?;
            if let Some(change) = self.client.next_change() {
                match &change {
                    Change::Window(window) => {
                        for origin in &window.origins {
                            self.origins.insert(origin.id.clone(), origin.state);
                        }
                    }
                    Change::Origin { origin, .. } => {
                        self.origins.insert(origin.id.clone(), origin.state);
                    }
                    Change::Fallback(_) => {
                        return Err(protocol("the daemon no longer serves the list"));
                    }
                    Change::Error { method, .. } if method == "frame" => {
                        return Err(protocol(format!("{change:?}")));
                    }
                    _ => {}
                }
                return Ok(change);
            }
            if self.client.is_closed() {
                return Err(protocol("the list connection closed"));
            }
            if !self.pending.is_empty() {
                let used = self.client.received(&self.pending);
                self.pending.drain(..used.min(self.pending.len()));
                if used > 0 {
                    continue;
                }
            }
            let n = self.reader.read(&mut buf).await?;
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "the daemon closed the list connection",
                ));
            }
            self.bytes_received = self.bytes_received.saturating_add(n as u64);
            self.pending.extend_from_slice(buf.get(..n).unwrap_or_default());
        }
    }

    fn sid(&mut self, kind: &str) -> String {
        let sid = format!("{kind}-{}", self.next_sid);
        self.next_sid = self.next_sid.saturating_add(1);
        sid
    }

    /// The state of an origin as the connection last saw it. This machine is connected.
    pub fn origin_state(&self, origin: &str) -> OriginState {
        if origin == "local" {
            return OriginState::Connected;
        }
        self.origins.get(origin).copied().unwrap_or(OriginState::Connected)
    }

    /// The most pages a read held at once without handing them out (at most one).
    pub fn unhanded_peak(&self) -> usize {
        self.unhanded_peak
    }

    /// Page requests reads sent, a window counted as one.
    pub fn pages_asked(&self) -> u64 {
        self.pages_asked
    }

    /// Bytes this connection read from the daemon.
    pub fn bytes_received(&self) -> u64 {
        self.bytes_received
    }

    /// Reads a view: a window, a walk by page, or rows by key. Take the pages with
    /// [`Reading::next`]; each is asked for only when the one before it was taken.
    pub async fn read(&mut self, read: Read) -> io::Result<Reading<'_, R, W>> {
        let (view, filter, rows) = match &read {
            Read::Window { view, filter, rows } => (*view, filter.clone(), (*rows).max(1)),
            Read::Walk { view, filter } => (*view, filter.clone(), WALK_WINDOW_ROWS),
            // The window of a read by key carries the origins; its one row is not given.
            Read::Keys(_) => (ListView::Live, None, 1),
        };
        let sid = self.sid("read");
        let mut sub = Sub::new(sid.clone(), "list").around(Anchor::End, rows);
        sub.view = Some(view);
        sub.filter = filter.clone();
        self.client.subscribe(sub).map_err(|error| protocol(error.to_string()))?;
        self.pages_asked = self.pages_asked.saturating_add(1);
        let state = match read {
            Read::Window { .. } => ReadState::Window,
            Read::Walk { .. } => ReadState::Walk { after: None },
            Read::Keys(keys) => ReadState::Keys { keys: keys.into() },
        };
        Ok(Reading { connection: self, sid, view, filter, state, window_taken: false })
    }

    /// Follows a view: a mirror with the keys the caller holds (`whole` when they were the
    /// whole view when saved, from `cursor` in its edition) and the keys it wants whatever their
    /// state. Changes come from [`Following::next`].
    pub async fn follow(
        &mut self,
        view: ListView,
        filter: Option<ListFilter>,
        held: impl IntoIterator<Item = ListKey>,
        whole: bool,
        cursor: Option<(Cursor, u32)>,
    ) -> io::Result<Following<'_, R, W>> {
        let sid = self.sid("follow");
        let mut sub = Sub::new(sid.clone(), "list");
        sub.view = Some(view);
        sub.filter = filter;
        if let Some((cursor, edition)) = cursor {
            sub = sub.from_cursor_in_edition(cursor, edition);
        }
        self.client
            .subscribe_mirror(sub, held, whole)
            .map_err(|error| protocol(error.to_string()))?;
        Ok(Following { connection: self, sid })
    }

    /// Rows as v1 gave them. A parent not among `rows` is read by key, [`KEYS_PER_PAGE`] a
    /// request; one that is missing or unknown gives no `spawnedBy`.
    pub async fn v1_rows(&mut self, rows: &[Summary]) -> io::Result<Vec<Value>> {
        let given: HashMap<(String, String), &Summary> =
            rows.iter().map(|row| (row_identity(&row.origin, &row.chat_id), row)).collect();
        let mut asked = HashSet::new();
        let wanted: Vec<ListKey> = rows
            .iter()
            .filter_map(|row| row.parent.as_ref())
            .map(|parent| row_identity(&parent.origin, &parent.chat_id))
            .filter(|id| !given.contains_key(id) && asked.insert(id.clone()))
            .map(|(origin, chat_id)| ListKey { last_activity: 0, chat_id, origin })
            .collect();
        let mut parents = HashMap::new();
        if !wanted.is_empty() {
            let mut reading = self.read(Read::Keys(wanted)).await?;
            while let Some(page) = reading.next().await? {
                for row in page.rows {
                    parents.insert(row_identity(&row.origin, &row.chat_id), row);
                }
            }
        }
        Ok(rows
            .iter()
            .map(|row| {
                let parent = row.parent.as_ref().and_then(|parent| {
                    let id = row_identity(&parent.origin, &parent.chat_id);
                    given.get(&id).copied().or_else(|| parents.get(&id))
                });
                crate::v1_row(row, self.origin_state(&row.origin), parent)
            })
            .collect())
    }

    /// Hands the transport back, for a caller that has finished with the list.
    pub fn into_parts(self) -> (R, W) {
        (self.reader, self.writer)
    }
}

enum ReadState {
    Window,
    /// The key the next page starts after; `None` before the window.
    Walk {
        after: Option<ListKey>,
    },
    Keys {
        keys: VecDeque<ListKey>,
    },
    Done,
}

/// A read in progress. Dropping it ends its subscription: the `unsub` is queued then and goes
/// out with the connection's next read from the socket (the `next` of a later read or follow
/// flushes what is queued first, `next_change`), so a caller that keeps the connection and reads
/// nothing more leaves the subscription open until it does, or until the connection closes.
pub struct Reading<'a, R, W>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    connection: &'a mut ListConnection<R, W>,
    sid: String,
    view: ListView,
    filter: Option<ListFilter>,
    state: ReadState,
    window_taken: bool,
}

/// What a read waits for.
enum Reply {
    Window { rows: Vec<Summary>, has_after: bool, after_key: Option<ListKey> },
    Page(crate::wire::PageResult<Summary>),
}

impl<R, W> Reading<'_, R, W>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    /// The next page, or `None` when the read is done.
    pub async fn next(&mut self) -> io::Result<Option<Rows>> {
        if !self.window_taken {
            let Reply::Window { rows, has_after, after_key } = self.reply().await? else {
                return Err(protocol("a page before the read's window"));
            };
            self.window_taken = true;
            self.hand();
            let next = match &self.state {
                ReadState::Walk { .. } if has_after => Some(ReadState::Walk {
                    after: Some(
                        after_key
                            .ok_or_else(|| protocol("a window with hasAfter and no afterKey"))?,
                    ),
                }),
                ReadState::Window | ReadState::Walk { .. } | ReadState::Done => {
                    Some(ReadState::Done)
                }
                // The window of a read by key only carried the origins.
                ReadState::Keys { .. } => None,
            };
            if let Some(next) = next {
                self.state = next;
                return Ok(Some(Rows { rows, ..Rows::default() }));
            }
        }
        match std::mem::replace(&mut self.state, ReadState::Done) {
            ReadState::Window | ReadState::Done | ReadState::Walk { after: None } => Ok(None),
            ReadState::Walk { after: Some(key) } => {
                let mut page = self.page(self.filter.clone());
                page.after = Some(Position::List(key));
                self.ask(page)?;
                let Reply::Page(reply) = self.reply().await? else {
                    return Err(protocol("a second window for one read"));
                };
                self.hand();
                if reply.has_after {
                    let key = reply
                        .after_key
                        .ok_or_else(|| protocol("a page with hasAfter and no afterKey"))?;
                    self.state = ReadState::Walk { after: Some(key) };
                }
                Ok(Some(Rows { rows: reply.rows, ..Rows::default() }))
            }
            ReadState::Keys { mut keys } => {
                if keys.is_empty() {
                    return Ok(None);
                }
                let count = keys.len().min(KEYS_PER_PAGE);
                let batch: Vec<PageKey> = keys.drain(..count).map(PageKey::Summary).collect();
                let mut page = self.page(None);
                page.keys = Some(batch);
                self.ask(page)?;
                let Reply::Page(reply) = self.reply().await? else {
                    return Err(protocol("a second window for one read"));
                };
                self.hand();
                let answered = reply.rows.len() + reply.missing.len() + reply.unknown.len();
                if answered == 0 && !reply.rest.is_empty() {
                    return Err(protocol("a keyed page that answered no key and has a rest"));
                }
                for key in reply.rest.into_iter().rev() {
                    keys.push_front(key);
                }
                self.state = ReadState::Keys { keys };
                Ok(Some(Rows { rows: reply.rows, missing: reply.missing, unknown: reply.unknown }))
            }
        }
    }

    fn page(&self, filter: Option<ListFilter>) -> Page {
        Page {
            sid: self.sid.clone(),
            stream: "list".into(),
            before: None,
            after: None,
            keys: None,
            view: Some(self.view),
            max_bytes: MAX_PAGE_BYTES as u32,
            filter,
            edition: None,
            fold: None,
        }
    }

    fn ask(&mut self, page: Page) -> io::Result<()> {
        self.connection.client.page(page).map_err(|error| protocol(error.to_string()))?;
        self.connection.pages_asked = self.connection.pages_asked.saturating_add(1);
        Ok(())
    }

    /// The page received is handed out (or, for a read by key's window, dropped).
    fn hand(&mut self) {
        self.connection.unhanded = self.connection.unhanded.saturating_sub(1);
    }

    /// Waits for this read's window or page. Changes of the read's own subscription (its
    /// deltas) are taken and dropped: a read is not a follow.
    async fn reply(&mut self) -> io::Result<Reply> {
        loop {
            let change = self.connection.next_change().await?;
            let reply = match change {
                Change::Window(window) if window.sid == self.sid => Reply::Window {
                    rows: window.rows,
                    has_after: window.has_after,
                    after_key: window.after_key,
                },
                Change::Page(page) if page.sid == self.sid => Reply::Page(page),
                Change::Error { sid: Some(sid), method, code, .. } if sid == self.sid => {
                    return Err(io::Error::other(format!("the list's {method}: {code}")));
                }
                // A refused `sub` or `page` that names no sid: the read holds the connection,
                // so it is this read's, and waiting on would never end.
                Change::Error { sid: None, method, code, .. }
                    if method == "sub" || method == "page" =>
                {
                    return Err(io::Error::other(format!("the list's {method}: {code}")));
                }
                Change::Dropped { sid, .. } if sid == self.sid => {
                    return Err(io::Error::other("the daemon dropped the read"));
                }
                _ => continue,
            };
            let connection = &mut *self.connection;
            connection.unhanded = connection.unhanded.saturating_add(1);
            connection.unhanded_peak = connection.unhanded_peak.max(connection.unhanded);
            return Ok(reply);
        }
    }
}

impl<R, W> Drop for Reading<'_, R, W>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    fn drop(&mut self) {
        // Queued here, sent with the connection's next request.
        let _ = self.connection.client.unsubscribe(&self.sid);
    }
}

/// A mirror in progress.
pub struct Following<'a, R, W>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    connection: &'a mut ListConnection<R, W>,
    sid: String,
}

impl<R, W> Following<'_, R, W>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    /// The mirror's subscription id, as its changes name it.
    pub fn sid(&self) -> &str {
        &self.sid
    }

    /// The next change of the mirror. Its credit is the bytes taken so far.
    pub async fn next(&mut self) -> io::Result<Change<Summary>> {
        self.connection.next_change().await
    }

    /// Adds keys the mirror holds whatever their state.
    pub fn want(&mut self, keys: impl IntoIterator<Item = ListKey>) -> io::Result<()> {
        self.connection.client.want(&self.sid, keys).map_err(|error| protocol(error.to_string()))
    }

    /// Removes wanted keys.
    pub fn unwant(&mut self, keys: impl IntoIterator<Item = ListKey>) -> io::Result<()> {
        self.connection.client.unwant(&self.sid, keys).map_err(|error| protocol(error.to_string()))
    }

    /// The state of an origin as the mirror last received it.
    pub fn origin_state(&self, origin: &str) -> OriginState {
        self.connection.origin_state(origin)
    }

    /// Resumes on a new transport after the old one dropped: the upgrade goes out now, and
    /// [`Following::next`] reads its answer and the mirror's resume from its cursor, after the
    /// changes still held from before the drop. A daemon that no longer serves the list is an
    /// error there.
    pub async fn reconnect(&mut self, reader: R, writer: W) -> io::Result<()> {
        let connection = &mut *self.connection;
        connection.client.disconnected();
        connection.pending.clear();
        connection.reader = reader;
        connection.writer = writer;
        connection.client.connected();
        connection.flush().await
    }
}
