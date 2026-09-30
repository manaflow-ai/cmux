import Foundation

/// How a workspace row's checklist presents when its summary line is
/// clicked: anchored popover (the default) or inline expansion under the
/// row. Raw values are the cmux.json wire strings; frozen.
public enum WorkspaceTodoChecklistStyle: String, CaseIterable, Sendable, SettingCodable {
    case popover
    case inline
}
