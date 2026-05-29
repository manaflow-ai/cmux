import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

enum SettingsConfigurationReview: Equatable {
    case settingsFile([String])
    case settingsOnly
    case action
    case debugOnly

    static func json(_ paths: String...) -> Self {
        .settingsFile(paths)
    }

    var searchAnchorIDs: [String] {
        guard case .settingsFile(let paths) = self else { return [] }
        return paths.compactMap(SettingsSearchIndex.anchorID(forSettingsPath:))
    }

    func validate(file: StaticString = #fileID, line: UInt = #line) {
        guard case .settingsFile(let paths) = self else { return }
        let unknownPaths = paths.filter { !CmuxSettingsFileStore.supportedSettingsJSONPaths.contains($0) }
        precondition(
            unknownPaths.isEmpty,
            "Unknown cmux.json settings path(s): \(unknownPaths.joined(separator: ", "))",
            file: file,
            line: line
        )
    }
}

extension View {
    @ViewBuilder
    func applyIf(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
