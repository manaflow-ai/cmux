internal import Foundation

extension ChangedFileItem {
    var filename: String {
        (path as NSString).lastPathComponent
    }

    var directoryPrefix: String {
        let directory = (path as NSString).deletingLastPathComponent
        return directory == "." || directory.isEmpty ? "" : directory + "/"
    }

    var oldFilename: String? {
        oldPath.map { ($0 as NSString).lastPathComponent }
    }

    var displayFilename: String {
        guard kind == .renamed, let oldFilename else { return filename }
        return String(
            format: String(
                localized: "changes.rename.format",
                defaultValue: "%1$@ → %2$@",
                bundle: .module
            ),
            oldFilename,
            filename
        )
    }

    var accessibilityLabel: String {
        String(
            format: String(
                localized: "changes.row.accessibility",
                defaultValue: "%1$@, %2$@, %3$lld additions, %4$lld deletions",
                bundle: .module
            ),
            filename,
            kind.localizedDisplayName,
            Int64(additions),
            Int64(deletions)
        )
    }
}
