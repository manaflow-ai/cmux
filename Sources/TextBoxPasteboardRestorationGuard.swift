import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os


// MARK: - Pasteboard Restoration
struct TextBoxPasteboardRestorationToken: Equatable {
    let changeCount: Int
    let fileURL: URL
}

enum TextBoxPasteboardRestorationGuard {
    static func token(
        afterWritingTemporaryFileURL fileURL: URL,
        to pasteboard: NSPasteboard
    ) -> TextBoxPasteboardRestorationToken {
        TextBoxPasteboardRestorationToken(
            changeCount: pasteboard.changeCount,
            fileURL: fileURL.standardizedFileURL
        )
    }

    static func shouldRestore(
        pasteboard: NSPasteboard,
        token: TextBoxPasteboardRestorationToken?
    ) -> Bool {
        guard let token else {
            return false
        }
        let temporaryPath = token.fileURL.standardizedFileURL.path
        let currentFileURLPaths = Set(
            PasteboardFileURLReader.fileURLs(from: pasteboard).map { $0.standardizedFileURL.path }
        )
        guard currentFileURLPaths.contains(temporaryPath) else {
            return false
        }
        guard pasteboard.changeCount == token.changeCount else {
            return currentFileURLPaths == [temporaryPath]
        }
        return true
    }

    static func isCurrentTemporaryWrite(
        pasteboard: NSPasteboard,
        token: TextBoxPasteboardRestorationToken?
    ) -> Bool {
        shouldRestore(pasteboard: pasteboard, token: token)
    }
}

