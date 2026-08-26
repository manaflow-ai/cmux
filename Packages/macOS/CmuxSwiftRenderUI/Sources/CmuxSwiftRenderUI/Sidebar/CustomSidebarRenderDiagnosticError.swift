import Foundation

/// Errors reported while preparing, mounting, or writing a custom-sidebar artifact.
public enum CustomSidebarRenderDiagnosticError: Error, LocalizedError, Sendable, Equatable {
    /// The requested bitmap dimensions are outside the safe 1...4096 range.
    case invalidSize
    /// The requested sidebar file does not exist.
    case fileMissing
    /// The sidebar path is neither a supported Swift nor JSON source file.
    case unsupportedFile
    /// Swift source evaluation did not produce a supported view tree.
    case noView
    /// The source file could not be read or decoded; the associated value gives the reason.
    case readFailed(String)
    /// AppKit could not mount the shared sidebar content view.
    case mountFailed
    /// AppKit produced no bitmap or PNG representation for the mounted view.
    case bitmapFailed
    /// The mounted view produced a fully transparent artifact.
    case blankOutput
    /// The PNG could not be written; the associated value gives the reason.
    case writeFailed(String)

    /// A localized explanation suitable for CLI and socket responses.
    public var errorDescription: String? {
        switch self {
        case .invalidSize:
            return String(
                localized: "sidebar.custom.render.invalidSize",
                defaultValue: "Render width and height must be between 1 and 4096.",
                bundle: .module
            )
        case .fileMissing:
            return String(
                localized: "sidebar.custom.render.fileMissing",
                defaultValue: "Sidebar file is missing.",
                bundle: .module
            )
        case .unsupportedFile:
            return String(
                localized: "sidebar.custom.render.unsupportedFile",
                defaultValue: "Sidebar file has an unsupported format.",
                bundle: .module
            )
        case .noView:
            return String(
                localized: "sidebar.custom.render.noView",
                defaultValue: "No supported SwiftUI view found.",
                bundle: .module
            )
        case let .readFailed(reason):
            return String(
                format: String(
                    localized: "sidebar.custom.render.readFailed",
                    defaultValue: "Failed to read sidebar file: %@",
                    bundle: .module
                ),
                reason
            )
        case .mountFailed:
            return String(
                localized: "sidebar.custom.render.mountFailed",
                defaultValue: "The sidebar could not be mounted.",
                bundle: .module
            )
        case .bitmapFailed:
            return String(
                localized: "sidebar.custom.render.bitmapFailed",
                defaultValue: "The mounted sidebar could not produce a PNG.",
                bundle: .module
            )
        case .blankOutput:
            return String(
                localized: "sidebar.custom.render.blankOutput",
                defaultValue: "The mounted sidebar produced no visible pixels.",
                bundle: .module
            )
        case let .writeFailed(reason):
            return String(
                format: String(
                    localized: "sidebar.custom.render.writeFailed",
                    defaultValue: "Failed to write the render artifact: %@",
                    bundle: .module
                ),
                reason
            )
        }
    }
}
