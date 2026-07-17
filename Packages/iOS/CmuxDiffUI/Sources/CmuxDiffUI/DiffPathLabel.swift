import SwiftUI

struct DiffPathLabel: View {
    let path: String
    let oldPath: String?
    let showRename: Bool

    var body: some View {
        if showRename, let oldPath, oldPath != path {
            HStack(spacing: 4) {
                Text(oldPath)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(path)
                    .foregroundStyle(.primary)
            }
            .font(.subheadline.monospaced())
        } else {
            HStack(spacing: 0) {
                if !directory.isEmpty {
                    Text(directory + "/")
                        .foregroundStyle(.secondary)
                }
                Text(filename)
                    .foregroundStyle(.primary)
            }
            .font(.subheadline.monospaced())
        }
    }

    private var directory: String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    private var filename: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
