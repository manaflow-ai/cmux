import CmuxTextMatching
import Foundation

/// What find-window matches and how, mirroring tmux `find-window -CNTir`.
struct RemoteTmuxFindWindowOptions: Equatable, Sendable {
    /// `-N`: match window names.
    var matchesWindowNames = true
    /// `-T`: match pane titles.
    var matchesPaneTitles = true
    /// `-C`: match pane contents, the full tmux history included.
    var matchesContents = true
    /// `.text` is fzf-style fuzzy names and titles plus a literal content search;
    /// `.glob` and `.regex` match all three the way tmux does (`-r` for regex).
    var syntax: PaneContentSyntax = .text
    /// `.ignore` is tmux's `-i`; `.smart` ignores case until the query has a capital.
    var caseMode: PaneContentCaseMode = .smart
}
