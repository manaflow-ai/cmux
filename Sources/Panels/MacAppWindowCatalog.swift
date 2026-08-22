import AppKit
import Foundation
import ScreenCaptureKit

/// Discovers the on-screen windows that ScreenCaptureKit can capture.
@MainActor
final class MacAppWindowCatalog {
    func loadWindows() async throws -> [MacAppWindowDescriptor] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let currentProcessID = NSRunningApplication.current.processIdentifier
        return content.windows.compactMap { window in
            guard let application = window.owningApplication,
                  application.processID != currentProcessID,
                  window.windowID != 0,
                  window.frame.width >= 80,
                  window.frame.height >= 50 else {
                return nil
            }
            let applicationName = application.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !applicationName.isEmpty else { return nil }
            return MacAppWindowDescriptor(
                windowID: window.windowID,
                processID: application.processID,
                applicationName: applicationName,
                bundleIdentifier: application.bundleIdentifier,
                title: window.title ?? "",
                frame: window.frame
            )
        }
        .sorted { lhs, rhs in
            if lhs.applicationName.localizedStandardCompare(rhs.applicationName) == .orderedSame {
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
            return lhs.applicationName.localizedStandardCompare(rhs.applicationName) == .orderedAscending
        }
    }

    func findWindow(for descriptor: MacAppWindowDescriptor) async throws -> SCWindow? {
        let windows = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ).windows
        return windows.first { window in
            window.windowID == descriptor.windowID
                && window.owningApplication?.processID == descriptor.processID
        }
    }
}
