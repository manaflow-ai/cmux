public import Foundation

/// The extension sheets on screen (Chromium install and permission prompts,
/// automation consent), so a debug-build control method can list them and
/// answer one exactly as its buttons do.
///
/// The dialog presenter opens an entry when it shows a sheet and closes it
/// when the sheet goes away; ``answer(_:accepted:)`` runs the sheet's own
/// answer path. Release builds never expose it to automation.
@MainActor
public final class BrowserExtensionOpenDialogs {
    /// One sheet on screen.
    public struct Dialog: Equatable, Sendable {
        /// The dialog id, unique for the process run.
        public var id: Int
        /// The sheet title (the question).
        public var title: String
        /// The exact target: extension name or folder.
        public var target: String
        /// The extension id, when the prompt names one.
        public var targetDetail: String?
        /// The accept button title.
        public var acceptTitle: String
        /// True for an automation consent, false for a Chromium prompt.
        public var isAutomation: Bool
    }

    /// The app's dialogs.
    public static let app = BrowserExtensionOpenDialogs()

    private var entries: [Int: (dialog: Dialog, answer: @MainActor (Bool) -> Void)] = [:]
    private var nextID = 1

    /// Creates an empty list.
    public init() {}

    /// The dialogs on screen, oldest first.
    public var waiting: [Dialog] { entries.values.map(\.dialog).sorted { $0.id < $1.id } }

    /// Records a sheet that is now on screen.
    ///
    /// - Parameters:
    ///   - content: The sheet's content.
    ///   - answer: The sheet's answer path (its buttons call the same).
    /// - Returns: The dialog id.
    @discardableResult
    public func open(_ content: BrowserExtensionPromptContent, answer: @escaping @MainActor (Bool) -> Void) -> Int {
        let id = nextID
        nextID += 1
        let dialog = Dialog(
            id: id, title: content.title, target: content.target, targetDetail: content.targetDetail,
            acceptTitle: content.acceptTitle, isAutomation: content.requester != nil
        )
        entries[id] = (dialog, answer)
        return id
    }

    /// Forgets a sheet that went away.
    public func close(_ id: Int) {
        entries[id] = nil
    }

    /// Answers a sheet as its accept or cancel button does.
    ///
    /// - Returns: False when no such sheet is on screen.
    @discardableResult
    public func answer(_ id: Int, accepted: Bool) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        entry.answer(accepted)
        return true
    }
}
