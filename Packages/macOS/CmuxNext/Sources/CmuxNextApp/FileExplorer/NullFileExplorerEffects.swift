import CmuxNextActions
import Foundation

/// Effects that do nothing: a view made after the App's services went away, or one with no effects given.
@MainActor
final class NullFileExplorerEffects: FileExplorerEffects {
    func openInCmux(_ file: URL, at position: FileLineLocation?) -> Bool { false }
    func openAsText(_ file: URL) -> Bool { false }
    func openInDefaultApp(_ item: URL) {}
    func revealInFinder(_ item: URL) {}
    func copy(_ text: String) {}
    func open(_ item: URL, withApp app: String) async throws {}
}
