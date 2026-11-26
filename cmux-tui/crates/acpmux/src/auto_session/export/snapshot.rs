//! One snapshot of a chat: what a new holder needs besides the events. The folder and the
//! agent's own session files ([`native`]) are read and cut into content-addressed chunks, and
//! one manifest names them with the chat's queue, draft and open turn. The manifest goes first: the store answers which chunks it lacks, so a folder
//! that did not change costs one request.

use std::sync::Arc;

use cmux_auto_session::AutoCloud;
use cmux_auto_session::chunks::Pack;
use cmux_auto_session::cloud::{AutoCloudError, CloudResult};
use cmux_auto_session::consts::{MANIFEST_VERSION, SNAPSHOT_MAX_BYTES};
use cmux_auto_session::wire::{
    Cwd, ErrorCode, Fence, Manifest, OpenTool, OpenTurn, QueuedPrompt, SnapshotPost,
};

use super::folder::{self, Folder, TooLarge};
use super::native::{self, AgentFile};
use crate::hub::{Hub, Session};

/// A snapshot the store took.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Stored {
    /// The store's number for it.
    pub snapshot: u64,
    /// The folder's tree as the snapshot has it (the git form): what a leftover patch is cut
    /// against.
    pub anchor: Option<String>,
}

/// Why a snapshot did not reach the store.
#[derive(Debug)]
pub(crate) enum Failed {
    /// The chat is past the size a Cloud copy may have.
    TooLarge,
    /// The store refused or did not answer.
    Cloud(AutoCloudError),
    /// The folder could not be read.
    Local(String),
}

impl Failed {
    pub fn too_large(&self) -> bool {
        matches!(self, Failed::TooLarge)
    }
}

impl std::fmt::Display for Failed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Failed::TooLarge => f.write_str("the chat is too large to keep a Cloud copy"),
            Failed::Cloud(error) => write!(f, "{error}"),
            Failed::Local(text) => write!(f, "the chat's folder could not be read: {text}"),
        }
    }
}

impl From<AutoCloudError> for Failed {
    fn from(error: AutoCloudError) -> Failed {
        if error.code() == Some(ErrorCode::TooLarge) {
            Failed::TooLarge
        } else {
            Failed::Cloud(error)
        }
    }
}

/// The folder's parts and the names of their chunks.
struct Parts<'a> {
    pack: Pack<'a>,
    cwd: Cwd,
}

fn parts<'a>(folder: &'a Folder) -> Result<Parts<'a>, Failed> {
    let mut pack = Pack::with_max(SNAPSHOT_MAX_BYTES);
    let mut add = |bytes: &'a [u8]| pack.add(bytes).map_err(|_| Failed::TooLarge);
    let cwd = match folder {
        Folder::Git(git) => Cwd::Git {
            remote: git.remote.clone(),
            branch: git.branch.clone(),
            base: git.base.clone(),
            bundle: add(git.bundle.as_slice())?,
            patch: add(git.patch.as_slice())?,
        },
        Folder::Plain(plain) => Cwd::Folder { tar: add(plain.tar.as_slice())? },
    };
    Ok(Parts { pack, cwd })
}

/// The chat's side of a manifest: its queue, draft and open turn, read now.
fn chat_state(hub: &Hub, session: &Session, tool: Option<OpenTool>) -> ChatState {
    let meta = session.meta();
    let queue =
        hub.auto_queue(session).into_iter().map(|(id, text)| QueuedPrompt { id, text }).collect();
    let open_turn = session.turn().map(|turn| OpenTurn {
        turn_id: turn.turn_id,
        prompt_id: turn.prompt_id,
        tool,
    });
    ChatState {
        harness: meta.harness,
        harness_session_id: meta.agent_session_id.unwrap_or_default(),
        draft: meta.composer_draft.unwrap_or_default(),
        queue,
        open_turn,
    }
}

struct ChatState {
    harness: String,
    harness_session_id: String,
    draft: String,
    queue: Vec<QueuedPrompt>,
    open_turn: Option<OpenTurn>,
}

/// Takes a snapshot of the chat as it is now and stores it under `fence`. `last_seq` is the last
/// event the store has: the events went first, and the snapshot covers the chat through them.
/// `tool` is the tool call in flight, if the caller follows one.
pub(crate) async fn upload<C: AutoCloud>(
    hub: &Arc<Hub>,
    cloud: &C,
    session: &Arc<Session>,
    fence: &Fence,
    last_seq: u64,
    tool: Option<OpenTool>,
    now: u64,
) -> Result<Stored, Failed> {
    let cwd = session.meta().cwd;
    let folder = tokio::task::spawn_blocking(move || folder::read(&cwd, SNAPSHOT_MAX_BYTES)).await;
    let folder = match folder {
        Ok(Ok(folder)) => folder,
        Ok(Err(error)) if error.downcast_ref::<TooLarge>().is_some() => {
            return Err(Failed::TooLarge);
        }
        Ok(Err(error)) => return Err(Failed::Local(format!("{error:#}"))),
        Err(error) => return Err(Failed::Local(error.to_string())),
    };
    let anchor = match &folder {
        Folder::Git(git) => Some(git.tree.clone()),
        Folder::Plain(_) => None,
    };
    // Read before the pack that names their bytes is made, so they outlive it.
    let files = agent_files(hub, session).await?;
    let Parts { mut pack, cwd } = parts(&folder)?;
    let native = native::add(&mut pack, &files).map_err(|_| Failed::TooLarge)?;
    let chat = chat_state(hub, session, tool);
    let manifest = Manifest {
        v: MANIFEST_VERSION,
        at: now,
        last_seq,
        harness: chat.harness,
        harness_session_id: chat.harness_session_id,
        cwd,
        queue: chat.queue,
        draft: chat.draft,
        open_turn: chat.open_turn,
        native,
    };
    let post = SnapshotPost { holder: fence.holder.clone(), epoch: fence.epoch, manifest };
    let snapshot = match cloud.post_snapshot(&session.id, &post).await {
        Ok(snapshot) => snapshot,
        Err(error) if error.code() == Some(ErrorCode::SnapshotIncomplete) => {
            send_missing(cloud, &session.id, fence, &pack, error.missing()).await?;
            cloud.post_snapshot(&session.id, &post).await?
        }
        Err(error) => return Err(error.into()),
    };
    Ok(Stored { snapshot, anchor })
}

/// The agent's own session files, read now ([`native`]). Files that cannot be read leave the
/// snapshot without them, and the next holder's agent then starts from the chat's log, as it
/// did before a snapshot carried them; only their size refuses the snapshot.
async fn agent_files(hub: &Arc<Hub>, session: &Arc<Session>) -> Result<Vec<AgentFile>, Failed> {
    let (hub, meta) = (Arc::clone(hub), session.meta());
    let id = meta.id.clone();
    let read = move || native::read(&hub, &meta, SNAPSHOT_MAX_BYTES);
    let error = match tokio::task::spawn_blocking(read).await {
        Ok(Ok(files)) => return Ok(files),
        Ok(Err(error)) if error.downcast_ref::<TooLarge>().is_some() => {
            return Err(Failed::TooLarge);
        }
        Ok(Err(error)) => format!("{error:#}"),
        Err(error) => error.to_string(),
    };
    tracing::warn!(session = %id, "the agent's own session files are not in this snapshot: {error}");
    Ok(Vec::new())
}

/// Stores the chunks the store said it lacks. A refusal that names none means it lacks them
/// all.
async fn send_missing<C: AutoCloud>(
    cloud: &C,
    id: &str,
    fence: &Fence,
    pack: &Pack<'_>,
    missing: &[String],
) -> CloudResult<()> {
    for chunk in pack.chunks() {
        if missing.is_empty() || missing.iter().any(|name| name == chunk.name) {
            cloud.put_chunk(id, chunk.name, chunk.bytes, fence).await?;
        }
    }
    Ok(())
}
