import AppKit
import CmuxNextDesign

/// A file-input answerer for tests whose pages never pick a file: every input is cancelled (a
/// test host cannot make an `NSOpenPanel` without its view service).
@MainActor final class NoFileInput: WebFileInputAnswering {
    func answerFileInput(allowsMultipleSelection: Bool, allowsDirectories: Bool, window: NSWindow?,
                         completion: @escaping @MainActor ([URL]?) -> Void) {
        completion(nil)
    }
}
