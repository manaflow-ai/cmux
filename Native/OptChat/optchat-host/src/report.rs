use std::fmt;
use std::path::PathBuf;
use std::sync::Arc;

use optchat_core::NodeId;

/// Something the host reports to its operator; nothing here stops the chat
/// except `Fatal`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Report {
    /// A line that is not valid JSON (a crash mid-write) was skipped when an
    /// old JSONL home or an export was imported (section 2).
    InvalidLine {
        file: PathBuf,
        line: usize,
        error: String,
    },
    /// An imported day file did not end in a newline (a crash mid-write).
    MissingNewline { file: PathBuf },
    /// A tree line for a node already loaded, or past the end of the log, was skipped.
    IgnoredNode {
        file: PathBuf,
        line: usize,
        node: NodeId,
        why: &'static str,
    },
    /// A home with only the old JSONL files was imported into its database
    /// (once); the old files were copied into `backup` first.
    Migrated {
        messages: u64,
        nodes: u64,
        hash: String,
        backup: PathBuf,
    },
    /// A migrated home's copy of its old files, a week old, imported again
    /// with the counts and hash of the migration, and deleted.
    BackupRetired {
        backup: PathBuf,
        messages: u64,
        nodes: u64,
    },
    /// The week-old copy did not check out; it is kept.
    BackupKept { backup: PathBuf, why: String },
    /// Saving the memory's checkpoint failed: the next start folds more of
    /// the log, nothing is lost.
    Checkpoint { error: String },
    /// A compactor node failed; only its first failure is reported (section 4.1).
    NodeFailed { node: NodeId, error: String },
    /// A compactor node failed with a request error that repeats on every
    /// try (`ErrorClass::permanent`): turns stop waiting for it; reported
    /// once per node with the error's class (status, type, message head).
    NodeStuck { node: NodeId, class: String },
    /// A write failed (its transaction rolled back); the chat stops writing
    /// until a restart.
    Fatal { error: String },
}

impl fmt::Display for Report {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Report::InvalidLine { file, line, error } => {
                write!(
                    f,
                    "skipped invalid line {line} of {}: {error}",
                    file.display()
                )
            }
            Report::MissingNewline { file } => {
                write!(f, "appended a missing final newline to {}", file.display())
            }
            Report::IgnoredNode {
                file,
                line,
                node,
                why,
            } => {
                write!(
                    f,
                    "skipped node {} at line {line} of {}: {why}",
                    node.name(),
                    file.display()
                )
            }
            Report::Migrated {
                messages,
                nodes,
                hash,
                backup,
            } => write!(
                f,
                "imported the JSONL memory into SQLite: {messages} messages, {nodes} nodes, hash {hash}; the old files are kept in {}",
                backup.display()
            ),
            Report::BackupRetired {
                backup,
                messages,
                nodes,
            } => write!(
                f,
                "deleted the old JSONL files' copy {} after checking it again ({messages} messages, {nodes} nodes, same hash as the migration)",
                backup.display()
            ),
            Report::BackupKept { backup, why } => write!(
                f,
                "kept the old JSONL files' copy {}: {why}",
                backup.display()
            ),
            Report::Checkpoint { error } => {
                write!(f, "saving the memory checkpoint failed: {error}")
            }
            Report::NodeStuck { node, class } => write!(
                f,
                "compactor node {} cannot be built ({class}); turns no longer wait for it, retried every {} s",
                node.name(),
                crate::STUCK_RETRY.as_secs()
            ),
            Report::NodeFailed { node, error } => {
                write!(
                    f,
                    "compactor node {} failed (retrying): {error}",
                    node.name()
                )
            }
            Report::Fatal { error } => write!(f, "chat stopped writing: {error}"),
        }
    }
}

/// Receives reports. Called without the chat's lock held, so it may call back
/// into the chat.
pub type Reporter = Arc<dyn Fn(&Report) + Send + Sync>;

/// The default reporter: one line on stderr each.
pub fn stderr_reporter() -> Reporter {
    Arc::new(|r: &Report| eprintln!("optchat: {r}"))
}
