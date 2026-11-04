public import Foundation

/// What a page says about a file of another machine (table `RemoteFiles`; #25581).
extension RemoteFilePageFiles {
    /// A file of another machine (#25581) whose machine did not answer.
    public static func remoteOffline(_ machine: String) -> String {
        String(format: String(localized: "filePages.remote.offline",
                              defaultValue: "“%@” is not connected. The file shows again when it reconnects.",
                              table: "RemoteFiles", bundle: .module), machine)
    }

    /// A file of another machine (#25581) larger than one write to it can carry.
    public static func remoteTooLargeToSave(_ machine: String) -> String {
        String(format: String(localized: "filePages.remote.tooLargeToSave",
                              defaultValue: "This file is too large to save to “%@” from this Mac. Files up to 12 MB save here.",
                              table: "RemoteFiles", bundle: .module), machine)
    }

    /// A machine whose cmux does not serve its files (an older daemon, a machine that is no Cloud VM).
    public static func remoteNoFiles(_ machine: String) -> String {
        String(format: String(localized: "filePages.remote.noFiles",
                              defaultValue: "“%@” does not share its files with this Mac. Update cmux on it to open its files here.",
                              table: "RemoteFiles", bundle: .module), machine)
    }

    /// An image, PDF or media file of another machine: this Mac previews only its own files.
    public static func remotePreview(_ name: String) -> String {
        String(format: String(localized: "filePages.remote.preview",
                              defaultValue: "“%@” is on another machine. cmux opens text files from there.",
                              table: "RemoteFiles", bundle: .module), name)
    }

    /// A path the machine refuses: outside its home folder, or not readable there.
    public static func remoteDenied(_ machine: String) -> String {
        String(format: String(localized: "filePages.remote.denied",
                              defaultValue: "“%@” did not allow reading this file. Files in its home folder open here.",
                              table: "RemoteFiles", bundle: .module), machine)
    }
}
