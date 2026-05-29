import CmuxSettings
import Foundation
import SwiftUI

public struct CmuxSettingsJSONPathModel: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let section: String

    public init(descriptor: CmuxSettingsJSONPathDescriptor) {
        path = descriptor.path
        section = descriptor.section
    }
}

public enum CmuxSettingsJSONPathList {
    public static var all: [CmuxSettingsJSONPathModel] {
        CmuxSettingsCatalog.supportedJSONPathDescriptors
            .sorted { $0.path < $1.path }
            .map(CmuxSettingsJSONPathModel.init(descriptor:))
    }

    public static func contains(_ path: String) -> Bool {
        CmuxSettingsCatalog.supportedJSONPaths.contains(path)
    }
}

public struct CmuxSettingsJSONPathListView: View {
    private let paths: [CmuxSettingsJSONPathModel]

    public init(paths: [CmuxSettingsJSONPathModel] = CmuxSettingsJSONPathList.all) {
        self.paths = paths
    }

    public var body: some View {
        List(paths) { path in
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: path.path)
                    .font(.system(.body, design: .monospaced))
                Text(verbatim: path.section)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
