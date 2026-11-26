//! A chat's Cloud copy into a local session. Owned by slice C (the Cloud machine daemon).
//!
//! The [`super::SessionImporter`] both sides call ([`Importer`]). It reads the events and the
//! newest snapshot and verifies every chunk ([`copy`]) before anything local changes, puts the
//! snapshot's folder in place ([`folder`]), and hands the hub a bundle of the events
//! ([`bundle`]) to import the way a moved chat arrives (`hub/auto_import.rs`).
//!
//! - A takeover gets a fresh folder from the manifest, its open turn settled `outcome_unknown`
//!   and the `machine_takeover` continuation at the head of the queue.
//! - A handback finds the chat here already: the Cloud's log replaces the local one under the
//!   same chat id, and the snapshot is put into the chat's own folder, whose state before is
//!   kept under a git ref ([`folder`]). A turn its log left open is settled too, and continued
//!   as a moved chat's turn is.
//! - A chat the person moved by hand arrives as one of the two. Its giver stopped the turn and
//!   logged the continuation before the copy, so the copy's queue carries it and it runs here
//!   once, with no open turn left to settle.
//! - A create has no copy yet: a folder of the repository and branch, and a new chat of the
//!   harness under the Cloud's chat id. Its first message is in the chat's inbox.
//! - A deliver for a chat that is here brings nothing: its messages are in the inbox.
//!
//! An import that fails leaves no chat and no folder it made.

mod bundle;
mod copy;
mod folder;
#[cfg(test)]
mod folder_tests;
mod mirror;
#[cfg(test)]
mod mirror_tests;
mod reconcile;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use cmux_auto_session::AutoCloud;
use cmux_auto_session::wire::{Manifest, SessionView};
pub(crate) use folder::BASE_REF;
use futures::future::BoxFuture;

use super::{ImportError, ImportReason, Imported, SessionImporter};
use crate::hub::{Hub, NewRequest};

/// The tool call a takeover's snapshot says was running (the manifest's `openTurn.tool`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct InFlight {
    pub turn_id: String,
    pub name: String,
    pub args: String,
}

/// What cut off a turn the copy's log never settled.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CutBy {
    /// The chat's last holder went away mid-turn, and this machine took the chat over.
    Takeover,
    /// The chat came home to its laptop with the turn open. A machine ends its turns before it
    /// hands a chat back, and a holder that gives a moved chat stops its turn first and logs
    /// the continuation itself (`hub/auto_give.rs`); what is left is a chat the store moved
    /// home from a machine that could no longer give it.
    Move,
}

/// What the hub needs besides the bundle to make the copy a session (`hub/auto_import.rs`).
#[derive(Clone, Debug)]
pub(crate) struct Arrival {
    /// The chat's id, here and in the Cloud.
    pub id: String,
    /// The agent the chat runs.
    pub harness: String,
    /// The chat ran the copy's agent conversation on this machine before: the agent's files of
    /// it that are here are this chat's own, and the copy's replace them (`bundle.rs`
    /// `agent_side`). Otherwise a file that is here is left as it is.
    pub own_agent: bool,
    /// How the turn the copy's log left open, if it left one, was cut off. It is settled here,
    /// once, and its continuation queued in these words.
    pub cut: CutBy,
    pub in_flight: Option<InFlight>,
    /// The text left in the composer.
    pub draft: String,
}

/// Brings chats' Cloud copies into `hub` over `cloud`.
pub struct Importer<C> {
    hub: Arc<Hub>,
    cloud: Arc<C>,
    /// Where a chat that is new here gets its folder: `<root>/<chat id>`.
    root: PathBuf,
    /// What each import answered, by chat and epoch: the same import again answers the same.
    done: Mutex<HashMap<(String, u64), Imported>>,
}

impl<C: AutoCloud + 'static> Importer<C> {
    pub fn new(hub: Arc<Hub>, cloud: Arc<C>, root: impl Into<PathBuf>) -> Arc<Importer<C>> {
        Arc::new(Importer { hub, cloud, root: root.into(), done: Mutex::default() })
    }

    async fn run(&self, view: &SessionView, reason: ImportReason) -> Result<Imported, ImportError> {
        let key = (view.id.clone(), view.epoch);
        let local = self.hub.auto_local(&view.id);
        // Answered before, and the chat it made is still here.
        let done = self.done.lock().unwrap_or_else(|e| e.into_inner()).get(&key).cloned();
        if let (Some(done), Some(_)) = (done, &local) {
            return Ok(done);
        }
        let here = matches!(reason, ImportReason::Deliver | ImportReason::Create);
        let imported = if local.is_some() && here {
            // The chat is here and nothing new is in the copy: only its inbox has news.
            answered(view, view.last_seq, view.snapshot)
        } else {
            let copy = copy::read(self.cloud.as_ref(), &view.id).await?;
            match &copy.snapshot {
                Some(snapshot) => {
                    let cwd = local.as_ref().map(|session| session.meta().cwd);
                    self.arrive(view, reason, &copy, snapshot, cwd).await?
                }
                None if copy.events.is_empty() => self.start_from_repo(view).await?,
                None => return Err(local_error("the chat's copy has events and no snapshot")),
            }
        };
        self.done.lock().unwrap_or_else(|e| e.into_inner()).insert(key, imported.clone());
        Ok(imported)
    }

    /// The copy becomes the chat here: its folder, then its log.
    async fn arrive(
        &self,
        view: &SessionView,
        reason: ImportReason,
        copy: &copy::CloudCopy,
        snapshot: &copy::Snapshot,
        existing: Option<PathBuf>,
    ) -> Result<Imported, ImportError> {
        let manifest = &snapshot.manifest;
        let fresh = existing.is_none();
        let dir = existing.unwrap_or_else(|| folder_under(&self.root, view));
        let label = format!("{}-{}", view.id, view.epoch);
        place_snapshot(&dir, fresh, manifest, snapshot, &label).await?;
        let staged = tempfile::tempdir().map_err(|e| local_error(format!("a temp folder: {e}")));
        let made = match staged {
            Ok(staged) => self.log_in(view, reason, copy, snapshot, &dir, staged.path()).await,
            Err(error) => Err(error),
        };
        if made.is_err() && fresh {
            folder::discard(dir).await;
        }
        made?;
        Ok(answered(view, copy.last_seq(), snapshot.number))
    }

    /// The copy's events and the agent's own session files as a bundle in `staged`, imported
    /// by the hub: the files are in the agent's store here before the agent first resumes.
    async fn log_in(
        &self,
        view: &SessionView,
        reason: ImportReason,
        copy: &copy::CloudCopy,
        snapshot: &copy::Snapshot,
        dir: &Path,
        staged: &Path,
    ) -> Result<(), ImportError> {
        let manifest = &snapshot.manifest;
        let base = self.hub.auto_local(&view.id).map(|session| session.meta());
        let family = {
            let config = self.hub.config.read().await;
            let profile = config.harnesses.get(&manifest.harness);
            profile.map(|profile| crate::config::derive_family(&manifest.harness, profile))
        };
        let stored = base.as_ref().and_then(|meta| meta.agent_session_id.clone());
        let taken = self.hub.auto_agent_session_taken(&view.id, &manifest.harness_session_id);
        if taken {
            let id = &view.id;
            tracing::warn!(session = %id, "auto session: the copy names another chat's agent");
        }
        let agent = bundle::agent_side(stored, manifest, &snapshot.native, taken);
        let meta =
            bundle::meta(view, manifest, &agent.session, dir, base, family).map_err(local_error)?;
        bundle::write(staged, &view.id, &meta, &copy.events, agent.files).map_err(local_error)?;
        let open = manifest.open_turn.as_ref();
        let in_flight = open.and_then(|turn| {
            let tool = turn.tool.as_ref()?;
            let (name, args) = (tool.name.clone(), tool.args.clone());
            Some(InFlight { turn_id: turn.turn_id.clone(), name, args })
        });
        let arrival = Arrival {
            id: view.id.clone(),
            harness: manifest.harness.clone(),
            own_agent: agent.own,
            cut: if reason == ImportReason::Handback { CutBy::Move } else { CutBy::Takeover },
            in_flight,
            draft: manifest.draft.clone(),
        };
        match self.hub.import_auto(staged, &arrival).await {
            Ok(_) => Ok(()),
            Err(error) => Err(local_error(error.message)),
        }
    }

    /// A chat started in the Cloud: a folder of its repository and branch, and a new chat of
    /// its harness under the Cloud's id.
    async fn start_from_repo(&self, view: &SessionView) -> Result<Imported, ImportError> {
        let Some(repo) = view.repo.clone() else {
            return Err(local_error("the chat has no copy and no repository to start from"));
        };
        let dir = folder_under(&self.root, view);
        let cloned = {
            let dir = dir.clone();
            tokio::task::spawn_blocking(move || folder::clone(&dir, &repo.remote, &repo.branch))
        };
        match cloned.await {
            Ok(done) => done.map_err(local_error)?,
            Err(error) => return Err(local_error(format!("the folder's task: {error}"))),
        }
        let request = NewRequest {
            cwd: Some(dir.clone()),
            harness: Some(view.harness.clone()).filter(|harness| !harness.is_empty()),
            ..NewRequest::default()
        };
        if let Err(error) = self.hub.new_session_with_id(request, Some(view.id.clone())).await {
            folder::discard(dir).await;
            return Err(local_error(error.message));
        }
        Ok(answered(view, 0, 0))
    }
}

fn local_error(text: impl Into<String>) -> ImportError {
    ImportError::Local(text.into())
}

/// What an import of `view` answers.
fn answered(view: &SessionView, last_seq: u64, snapshot: u64) -> Imported {
    let SessionView { id, epoch, .. } = view;
    Imported { session_id: id.clone(), epoch: *epoch, last_seq, snapshot }
}

/// Where a chat that is new on this machine gets its folder: `<root>/<chat id>`.
fn folder_under(root: &Path, view: &SessionView) -> PathBuf {
    let SessionView { id, .. } = view;
    root.join(id)
}

/// The snapshot's folder at `dir`, off the async threads: git and file work.
async fn place_snapshot(
    dir: &Path,
    fresh: bool,
    manifest: &Manifest,
    snapshot: &copy::Snapshot,
    label: &str,
) -> Result<(), ImportError> {
    let (dir, cwd, label) = (dir.to_owned(), manifest.cwd.clone(), label.to_owned());
    let (first, patch) = (snapshot.first.clone(), snapshot.patch.clone());
    let work = move || folder::place(&dir, fresh, &cwd, &first, &patch, &label);
    match tokio::task::spawn_blocking(work).await {
        Ok(placed) => placed.map_err(local_error),
        Err(error) => Err(local_error(format!("the folder's task: {error}"))),
    }
}

impl<C: AutoCloud + 'static> SessionImporter for Importer<C> {
    fn import<'a>(
        &'a self,
        session: &'a SessionView,
        reason: ImportReason,
    ) -> BoxFuture<'a, Result<Imported, ImportError>> {
        Box::pin(self.run(session, reason))
    }
}
