//! Reads a chat's Cloud copy whole: every event, the newest snapshot's manifest, and every
//! chunk it names (the folder's and the agent's own files'), each checked against its name. Nothing local changes here, so a copy with
//! a chunk missing fails before a chat or a folder exists.

use cmux_auto_session::AutoCloud;
use cmux_auto_session::chunks;
use cmux_auto_session::consts::SNAPSHOT_MAX_BYTES;
use cmux_auto_session::wire::{Cwd, ErrorCode, Manifest, SeqRecord};

use super::local_error;
use crate::auto_session::ImportError;
use crate::auto_session::export::native::AgentFile;

/// A snapshot with its files read.
pub(super) struct Snapshot {
    /// The snapshot's number in the store.
    pub number: u64,
    pub manifest: Manifest,
    /// A git folder's bundle of local commits, or a plain folder's tar. Empty: none.
    pub first: Vec<u8>,
    /// A git folder's patch of uncommitted work. Empty: none.
    pub patch: Vec<u8>,
    /// The agent's own session files (the manifest's `native`), each read whole.
    pub native: Vec<AgentFile>,
}

/// A chat's copy.
pub(super) struct CloudCopy {
    /// Every event, in order from seq 1.
    pub events: Vec<SeqRecord>,
    /// None: the chat has no snapshot yet.
    pub snapshot: Option<Snapshot>,
}

impl CloudCopy {
    pub fn last_seq(&self) -> u64 {
        self.events.last().map_or(0, |event| event.seq)
    }
}

pub(super) async fn read<C: AutoCloud>(cloud: &C, id: &str) -> Result<CloudCopy, ImportError> {
    let snapshot = match cloud.snapshot(id).await {
        Ok(answer) => Some(answer),
        Err(error) if error.code() == Some(ErrorCode::NoSnapshot) => None,
        Err(error) => return Err(error.into()),
    };
    let events = events(cloud, id).await?;
    let snapshot = match snapshot {
        None => None,
        Some(answer) => {
            let manifest = answer.manifest;
            chunks::validate(&manifest).map_err(|error| local_error(error.to_string()))?;
            let none: &[String] = &[];
            let (first, patch) = match &manifest.cwd {
                Cwd::Git { bundle, patch, .. } => (bundle.as_slice(), patch.as_slice()),
                Cwd::Folder { tar } => (tar.as_slice(), none),
            };
            // What the files may still add up to. The store counts each chunk once, so a
            // manifest that names one chunk many times is small there and large here.
            let mut left = SNAPSHOT_MAX_BYTES;
            let first = file(cloud, id, first, &mut left).await?;
            let patch = file(cloud, id, patch, &mut left).await?;
            let mut native = Vec::new();
            for named in &manifest.native {
                let bytes = file(cloud, id, &named.chunks, &mut left).await?;
                let (label, path) = (named.label.clone(), named.path.clone());
                native.push(AgentFile { label, path, bytes });
            }
            Some(Snapshot { number: answer.snapshot, manifest, first, patch, native })
        }
    };
    Ok(CloudCopy { events, snapshot })
}

/// Every event of the chat, page by page, checked to run from seq 1 with no gap.
async fn events<C: AutoCloud>(cloud: &C, id: &str) -> Result<Vec<SeqRecord>, ImportError> {
    let mut all: Vec<SeqRecord> = Vec::new();
    loop {
        let after = all.last().map_or(0, |event| event.seq);
        let page = cloud.events(id, after, None).await?;
        if page.events.is_empty() {
            break;
        }
        for event in page.events {
            let next = all.last().map_or(1, |last| last.seq + 1);
            if event.seq != next {
                let found = event.seq;
                return Err(local_error(format!("the copy's events skip from {next} to {found}")));
            }
            all.push(event);
        }
        if all.last().is_some_and(|last| last.seq >= page.last_seq) {
            break;
        }
    }
    Ok(all)
}

/// One file of the snapshot: its chunks in order, each the bytes its name says. `left` is what
/// the snapshot's files may still add up to (a chat keeps at most [`SNAPSHOT_MAX_BYTES`]); a
/// file that goes past it fails the import before it is whole in memory.
async fn file<C: AutoCloud>(
    cloud: &C,
    id: &str,
    names: &[String],
    left: &mut u64,
) -> Result<Vec<u8>, ImportError> {
    let mut whole = Vec::new();
    for name in names {
        let bytes = cloud.chunk(id, name).await?;
        chunks::check(name, &bytes).map_err(|error| local_error(error.to_string()))?;
        let size = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
        let Some(rest) = left.checked_sub(size) else {
            return Err(local_error("the copy's files are larger than a chat's Cloud copy may be"));
        };
        *left = rest;
        whole.extend_from_slice(&bytes);
    }
    Ok(whole)
}
