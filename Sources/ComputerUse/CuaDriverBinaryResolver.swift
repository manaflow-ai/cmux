import Foundation

struct CuaDriverBinaryResolution: Equatable, Sendable {
    enum Source: String, CaseIterable, Sendable {
        case setting
        case environment
        case bundleHelper
        case applications
    }

    let url: URL
    let source: Source
}

struct CuaDriverBinaryResolver {
    static let environmentKey = "CMUX_CUA_DRIVER_PATH"
    static let applicationsURL = URL(fileURLWithPath: "/Applications/CuaDriver.app/Contents/MacOS/cua-driver")

    static func bundleHelperURL(in bundle: Bundle = .main) -> URL {
        bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("cua-driver", isDirectory: false)
    }

    func resolve(
        settingValue: String,
        environment: [String: String],
        bundleHelperURL: URL,
        fileExists: (URL) -> Bool
    ) -> CuaDriverBinaryResolution? {
        for candidate in candidates(
            settingValue: settingValue,
            environment: environment,
            bundleHelperURL: bundleHelperURL
        ) {
            if fileExists(candidate.url) {
                return candidate
            }
        }
        return nil
    }

    func candidates(
        settingValue: String,
        environment: [String: String],
        bundleHelperURL: URL
    ) -> [CuaDriverBinaryResolution] {
        var candidates: [CuaDriverBinaryResolution] = []
        if let url = fileURL(from: settingValue) {
            candidates.append(CuaDriverBinaryResolution(url: url, source: .setting))
        }
        if let url = fileURL(from: environment[Self.environmentKey] ?? "") {
            candidates.append(CuaDriverBinaryResolution(url: url, source: .environment))
        }
        candidates.append(CuaDriverBinaryResolution(url: bundleHelperURL, source: .bundleHelper))
        candidates.append(CuaDriverBinaryResolution(url: Self.applicationsURL, source: .applications))
        return candidates
    }

    private func fileURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
    }
}
