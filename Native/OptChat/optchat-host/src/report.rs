use std::fmt;
use std::path::PathBuf;
use std::sync::Arc;

use optchat_core::NodeId;

/// Something the host reports to its operator; nothing here stops the chat
/// except `Fatal`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Report {
    /// A line that is not valid JSON (a crash mid-write) was skipped at load (section 2).
    InvalidLine {
        file: PathBuf,
        line: usize,
        error: String,
    },
    /// A file did not end in a newline; one was appended so the next write
    /// starts on its own line (section 2).
    MissingNewline { file: PathBuf },
    /// A tree line for a node already loaded, or past the end of the log, was skipped.
    IgnoredNode {
        file: PathBuf,
        line: usize,
        node: NodeId,
        why: &'static str,
    },
    /// A compactor node failed; only its first failure is reported (section 4.1).
    NodeFailed { node: NodeId, error: String },
    /// A write failed. The file may hold a partial line, so the chat stops
    /// writing until a restart repairs it at load.
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
