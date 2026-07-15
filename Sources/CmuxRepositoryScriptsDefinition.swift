import Foundation

struct CmuxRepositoryScriptsDefinition: Codable, Sendable, Equatable {
    var setup: String?
    var archive: String?

    init(setup: String? = nil, archive: String? = nil) {
        self.setup = setup
        self.archive = archive
    }

    var normalized: Self {
        Self(setup: Self.nonblank(setup), archive: Self.nonblank(archive))
    }

    var isEmpty: Bool {
        let value = normalized
        return value.setup == nil && value.archive == nil
    }

    private static func nonblank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
