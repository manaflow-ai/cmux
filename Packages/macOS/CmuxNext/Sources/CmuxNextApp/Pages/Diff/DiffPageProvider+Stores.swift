import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The diff tab's stores (coordinator decision PAGE-PREFS): the display
/// prefs as `diff.*` settings and the "Viewed" marks next to the recents. The
/// page reads and writes them only through these ops, never web storage.
final class DiffPageStores {
    let prefs: any DiffPrefsStoring
    let viewed: DiffViewedFiles

    init(prefs: any DiffPrefsStoring, viewed: DiffViewedFiles) {
        self.prefs = prefs
        self.viewed = viewed
    }
}

extension DiffPageProvider {
    static let prefsGetOp = "cmux.diff.prefs.get"
    static let prefsSetOp = "cmux.diff.prefs.set"
    static let viewedListOp = "cmux.diff.viewed.list"
    static let viewedSetOp = "cmux.diff.viewed.set"
    static let viewedClearOp = "cmux.diff.viewed.clear"
    static let storeOps = [prefsGetOp, prefsSetOp, viewedListOp, viewedSetOp, viewedClearOp]

    /// Answers a store op; nil for any other op.
    func storeCall(_ op: String, params: JSONValue) async throws -> JSONValue? {
        guard Self.storeOps.contains(op) else { return nil }
        guard let stores else { throw PageError.unknownOp(op) }
        switch op {
        case Self.prefsGetOp:
            return ["prefs": .object(stores.prefs.prefs())]
        case Self.prefsSetOp:
            guard let key = params["key"]?.stringValue, let value = params["value"], DiffPrefKey.accepts(key, value) else {
                throw PageError.invalidParams("unknown pref or value")
            }
            do {
                try await stores.prefs.setPref(key, to: value)
            } catch {
                throw PageError(code: "cmux.diff.prefs_unavailable", message: String(describing: error))
            }
            return .object([:])
        default:
            let key = try await viewedScope(params["scope"])
            if op == Self.viewedListOp {
                let files = await stores.viewed.list(key)
                return ["files": .array(files.map { ["path": .string($0.path), "fingerprint": .string($0.fingerprint)] })]
            }
            if op == Self.viewedSetOp {
                guard let path = params["file"]?["path"]?.stringValue, let fingerprint = params["file"]?["fingerprint"]?.stringValue,
                      !path.isEmpty, path.utf8.count <= 4096, fingerprint.utf8.count <= 128 else {
                    throw PageError.invalidParams("file {path, fingerprint} is required")
                }
                await stores.viewed.set(.init(path: path, fingerprint: fingerprint), in: key)
            } else {
                guard let path = params["path"]?.stringValue else { throw PageError.invalidParams("path is required") }
                await stores.viewed.clear(path, in: key)
            }
            return .object([:])
        }
    }

    /// The store key of a page scope `{repoRoot, source}`. A tab reads and
    /// writes only the marks of the repository it shows.
    private func viewedScope(_ scope: JSONValue?) async throws -> String {
        guard let repoRoot = scope?["repoRoot"]?.stringValue, let source = scope?["source"]?.stringValue,
              !source.isEmpty, source.utf8.count <= 4096 else { throw PageError.invalidParams("scope {repoRoot, source} is required") }
        guard let shown = try? await ready?.value.config["payload"]?["repoRoot"]?.stringValue, shown == repoRoot else {
            throw PageError(code: "notAllowed", message: "Not this tab's repository")
        }
        return DiffViewedFiles.key(repoRoot: repoRoot, source: source)
    }

    /// The config with the stores' part: the prefs for first paint
    /// (`viewerOptions`, `layout`) and the store ops in `ops`.
    func withStores(_ config: JSONValue) -> JSONValue {
        guard let stores, case .object(var members) = config else { return config }
        let ops = (members["ops"]?.arrayValue ?? []) + Self.storeOps.map(JSONValue.string)
        members["ops"] = .array(ops)
        if case .object(var payload)? = members["payload"] {
            let prefs = stores.prefs.prefs()
            payload["viewerOptions"] = .object(prefs)
            if let layout = prefs["layout"], payload["layoutSource"]?.stringValue != "explicit" { payload["layout"] = layout }
            members["payload"] = .object(payload)
        }
        return .object(members)
    }
}
