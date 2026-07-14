import AppKit
import Foundation

@MainActor
final class CmuxRunURLConfirmationGate: NSObject {
    weak var checkbox: NSButton?
    private weak var runButton: NSButton?

    init(runButton: NSButton) {
        self.runButton = runButton
    }

    @objc func reviewStateChanged(_ sender: NSButton) {
        runButton?.isEnabled = sender.state == .on
    }
}
