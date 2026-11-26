#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport

/// User-facing copy the directory picker shows for search failures.
extension MobileTaskDirectorySearchFailure {
    var pickerMessage: String {
        switch self {
        case .unsupported:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.unsupported",
                defaultValue: "Update cmux on this Mac to search its folders. You can still choose a recent location."
            )
        case .unavailable:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.unavailable",
                defaultValue: "Reconnect to this Mac, then try again."
            )
        case .timedOut:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.timeout",
                defaultValue: "This Mac took too long to search. Try again."
            )
        case .authorizationRequired:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.authorization",
                defaultValue: "Sign in again on this device and Mac, then retry."
            )
        case .rejected, .cancelled:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.generic",
                defaultValue: "The folder search failed. Try again."
            )
        }
    }
}

/// User-facing copy the directory picker shows for folder-listing failures.
extension MobileTaskDirectoryListFailure {
    var pickerTitle: String {
        switch self {
        case .permissionDenied, .unreadable:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.access.title",
                defaultValue: "Folder Access Needed"
            )
        case .unsupported:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.update.title",
                defaultValue: "Update cmux on This Mac"
            )
        default:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.title",
                defaultValue: "Couldn’t Open Folder"
            )
        }
    }

    var pickerMessage: String {
        switch self {
        case .invalidPath:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.invalid",
                defaultValue: "Choose another location and try again."
            )
        case .unavailable:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.unavailable",
                defaultValue: "Reconnect to this Mac, then try again."
            )
        case .timedOut:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.timeout",
                defaultValue: "This folder took too long to load. Check the Mac or network volume, then retry."
            )
        case .authorizationRequired:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.authorization",
                defaultValue: "Sign in again on this device and Mac, then retry."
            )
        case .unsupported:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.update.message",
                defaultValue: "Install the latest cmux on the Mac to browse every accessible folder."
            )
        case .notFound, .notDirectory:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.missing",
                defaultValue: "This folder moved or no longer exists. Choose another location."
            )
        case .permissionDenied:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.permission",
                defaultValue: "cmux does not have permission to read this folder on the Mac. Allow access in Mac System Settings › Privacy & Security › Files & Folders, or grant cmux Full Disk Access, then retry."
            )
        case .unreadable:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.unreadable",
                defaultValue: "The Mac can see this folder but cannot read its contents."
            )
        case .rejected, .cancelled:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.generic",
                defaultValue: "The Mac could not list this folder. cmux may not have permission to read it yet. Allow access in Mac System Settings › Privacy & Security › Files & Folders, or grant cmux Full Disk Access, then retry."
            )
        }
    }
}

/// The short provenance label the directory picker shows on a suggested folder.
extension MobileTaskDirectorySource {
    var pickerLabel: String {
        switch self {
        case .filesystemSearch:
            L10n.string("mobile.taskComposer.directoryPicker.source.filesystem", defaultValue: "On this Mac")
        case .activeTerminal:
            L10n.string("mobile.taskComposer.directoryPicker.source.activeTerminal", defaultValue: "Focused terminal")
        case .activeWorkspace:
            L10n.string("mobile.taskComposer.directoryPicker.source.activeWorkspace", defaultValue: "Current workspace")
        case .templateDefault:
            L10n.string("mobile.taskComposer.directoryPicker.source.template", defaultValue: "Template default")
        case .lastSuccessful:
            L10n.string("mobile.taskComposer.directoryPicker.source.last", defaultValue: "Last used")
        case .openWorkspace, .openTerminal:
            L10n.string("mobile.taskComposer.directoryPicker.source.open", defaultValue: "Open on this Mac")
        case .recentSuccessful:
            L10n.string("mobile.taskComposer.directoryPicker.source.recent", defaultValue: "Recent task")
        case .home:
            L10n.string("mobile.taskComposer.directoryPicker.source.home", defaultValue: "Home folder")
        }
    }
}
#endif
