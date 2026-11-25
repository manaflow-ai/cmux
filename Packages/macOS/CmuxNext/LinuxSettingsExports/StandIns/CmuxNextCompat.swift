// CmuxNextCompat for the Linux settings exporter (scripts/cmux-next/regenerate-settings-exports-linux.sh): the few
// names the settings model reads. The Mac builds the real module (Sources/CmuxNextCompat).
public import Foundation

extension FileManager {
    /// The Mac's checked file manager reports a blocking call on the main thread; the exporter has no main thread
    /// to guard, so it is the plain one.
    public static var checked: FileManager { .default }
}
