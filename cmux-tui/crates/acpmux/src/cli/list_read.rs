//! The crate's one list source (agent service v2, the design doc, row 7b). A list caller opens
//! its own socket and asks for the upgrade naming `list` as that socket's first request
//! (`acpmux_client::tokio_list`); the v1 `Client` it already holds has sent requests and cannot
//! be upgraded. The daemon is the one reader of `acpmux.v2`: on its old answer (method not
//! found, or `list` not in the setting) [`open`] gives `None` and the caller runs its v1 path
//! whole. Each v1 path is a named fallback in `single_shot_list_tests.rs`.

use acpmux_client::tokio_list::{self, ListConnection, Opened, Read, Rows};
use acpmux_client::wire::{ListFilter, ListView};
use acpmux_book::index::Summary;
use anyhow::{Context as _, Result};

use crate::local_stream;

/// A list connection on the daemon's socket.
pub(crate) type Connection = ListConnection<local_stream::ReadHalf, local_stream::WriteHalf>;

/// A list connection to this home's daemon, or `None` for a daemon without the list surface,
/// whose caller runs its v1 path.
pub(crate) async fn open() -> Result<Option<Box<Connection>>> {
    open_at(&crate::config::socket_path()).await
}

/// [`open`] on the socket at `path`.
pub(crate) async fn open_at(path: &std::path::Path) -> Result<Option<Box<Connection>>> {
    let stream = local_stream::connect(path)
        .await
        .with_context(|| format!("connecting to the daemon at {}", path.display()))?;
    let (reader, writer) = local_stream::split(stream);
    match tokio_list::open(reader, writer).await.context("the list's upgrade")? {
        Opened::List(connection) => Ok(Some(connection)),
        Opened::Fallback { .. } => Ok(None),
    }
}

/// Every row of `view` from its head, page by page, newest first. Each page is taken before
/// the next is asked for; `keep` sees each page and says whether the walk goes on.
pub(crate) async fn walk(
    connection: &mut Connection,
    view: ListView,
    filter: Option<ListFilter>,
    mut keep: impl FnMut(&Rows) -> bool,
) -> Result<Vec<Summary>> {
    let mut reading = connection.read(Read::Walk { view, filter }).await?;
    let mut rows = Vec::new();
    while let Some(page) = reading.next().await? {
        let more = keep(&page);
        rows.extend(page.rows);
        if !more {
            break;
        }
    }
    Ok(rows)
}
