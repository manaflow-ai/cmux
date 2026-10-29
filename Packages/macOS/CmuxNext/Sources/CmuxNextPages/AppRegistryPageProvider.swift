public import CmuxNextSettings
public import Foundation

/// The App Store page's community ops (`cmux.registry.*`, custom-panes-DESIGN.md
/// section 6.4), answered over the person's Cloud session (``AppRegistryAPI``).
///
/// - Reads: `me`, `listings`, `submissions`, and for reviewers `review.queue` and
///   `review.file`.
/// - `submit` packs the local app on the Mac (``Pack``) and sends it.
/// - `get` downloads an approved bundle and hands it to the app supervisor (``Put``), which
///   checks it against the listing's hash before it joins the catalog; installing
///   it is the ordinary `cmux.apps.install` behind its own sheet.
/// - `submit` and `review.decide` publish or decide something in the person's name,
///   so they run only after the host's native sheet (`context.confirmed`).
@MainActor
public final class AppRegistryPageProvider: PageProvider {
    public nonisolated static let prefix = "cmux.registry."
    nonisolated static let confirmedOps: Set<String> = ["cmux.registry.submit", "cmux.registry.review.decide"]

    /// Packs the local `app` for review under `publisher`: the request body's
    /// `manifest` and `files` (``AppRegistrySubmission`` in CmuxNextApps).
    public typealias Pack = @MainActor (_ app: String, _ publisher: String) async throws(PageError)
        -> (manifest: JSONValue, files: [String: String])
    /// Hands an approved bundle to the app supervisor (`apps.registry.put`).
    public typealias Put = @MainActor (_ app: String, _ version: String, _ sha256: String, _ files: [String: String]) async throws(PageError) -> Void

    private let api: AppRegistryAPI
    private let pack: Pack
    private let put: Put

    public init(api: AppRegistryAPI, pack: @escaping Pack, put: @escaping Put) {
        self.api = api
        self.pack = pack
        self.put = put
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op.hasPrefix(Self.prefix) else { throw PageError.unknownOp(op) }
        if Self.confirmedOps.contains(op), !context.confirmed {
            throw PageError(code: "cmux.page.unconfirmed", message: "this needs the native confirmation")
        }
        switch String(op.dropFirst(Self.prefix.count)) {
        case "me": return try await me()
        case "listings":
            var query: [String: String] = [:]
            if let text = params["query"]?.stringValue, !text.isEmpty { query["query"] = text }
            if let cursor = params["cursor"]?.stringValue, !cursor.isEmpty { query["cursor"] = cursor }
            return try await api.request("GET", "listings", query: query, signed: false)
        case "submissions": return try await api.request("GET", "submissions")
        case "submit": return try await submit(params)
        case "review.queue":
            let queue = try await api.request("GET", "review/queue")
            let rows = (queue["submissions"]?.arrayValue ?? []).map(Self.queueRow)
            return ["submissions": .array(rows)]
        case "review.file":
            let id = try Self.submissionID(params)
            guard let path = params["path"]?.stringValue, !path.isEmpty else { throw PageError.invalidParams("path is required") }
            return try await api.request("GET", "review/submissions/\(id)/files", query: ["path": path])
        case "review.decide":
            let id = try Self.submissionID(params)
            guard let decision = params["decision"]?.stringValue, ["approve", "reject"].contains(decision) else {
                throw PageError.invalidParams("decision is approve or reject")
            }
            let body: JSONValue = ["decision": .string(decision), "reason": .string(params["reason"]?.stringValue ?? "")]
            return try await api.request("POST", "review/submissions/\(id)", body: body)
        case "get": return try await get(params)
        default: throw PageError.unknownOp(op)
        }
    }

    /// `{signedIn, user, reviewer, publishers}`; signed out is an answer, not an error.
    private func me() async throws(PageError) -> JSONValue {
        do throws(PageError) {
            var value = try await api.request("GET", "me").objectValue ?? [:]
            value["signedIn"] = true
            return .object(value)
        } catch {
            if error.code == AppRegistryAPI.signedOut.code { return ["signedIn": false] }
            throw error
        }
    }

    /// Packs the local app and sends it for review under `publisher`.
    private func submit(_ params: JSONValue) async throws(PageError) -> JSONValue {
        guard let app = params["app"]?.stringValue, let publisher = params["publisher"]?.stringValue else {
            throw PageError.invalidParams("app and publisher are required")
        }
        let packed = try await pack(app, publisher)
        var body: [String: JSONValue] = ["manifest": packed.manifest, "files": .object(packed.files.mapValues(JSONValue.string))]
        if let notes = params["notes"]?.stringValue, !notes.isEmpty { body["notes"] = .string(notes) }
        return try await api.request("POST", "submissions", body: .object(body))
    }

    /// Downloads approved `app@version` and hands it to the supervisor.
    private func get(_ params: JSONValue) async throws(PageError) -> JSONValue {
        guard let app = params["app"]?.stringValue, let version = params["version"]?.stringValue else {
            throw PageError.invalidParams("app and version are required")
        }
        let parts = app.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, Self.isAppID(publisher: parts[0], name: parts[1]),
              version.range(of: #"^[0-9A-Za-z.+-]{1,64}$"#, options: .regularExpression) != nil
        else { throw PageError.invalidParams("not an App Store app or version") }
        // The hash comes from the listing, the files from the bundle: the supervisor checks
        // one against the other before anything is written.
        let listing = try await api.request("GET", "apps/\(parts[0])/\(parts[1])", signed: false)
        let listed = listing["versions"]?.arrayValue?.first { $0["version"]?.stringValue == version }
        let bundle = try await api.request("GET", "apps/\(parts[0])/\(parts[1])/versions/\(version)/bundle", signed: false)
        guard let sha256 = listed?["sha256"]?.stringValue,
              bundle["app"]?.stringValue == app, bundle["version"]?.stringValue == version,
              let files = bundle["files"]?.objectValue
        else { throw PageError(code: "registry.failed", message: "the App Store sent another bundle") }
        try await put(app, version, sha256, files.compactMapValues(\.stringValue))
        return ["app": .string(app), "version": .string(version)]
    }

    /// The manifest schema's App Store id: a publisher of 1 to 39 and a name of 1 to 64
    /// lowercase letters, digits and `-`, each starting with a letter or digit.
    public nonisolated static func isAppID(publisher: String, name: String) -> Bool {
        publisher.range(of: #"^[a-z0-9][a-z0-9-]{0,38}$"#, options: .regularExpression) != nil
            && name.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil
    }

    private static func submissionID(_ params: JSONValue) throws(PageError) -> String {
        guard let id = params["id"]?.stringValue, id.range(of: #"^sub_[0-9a-f]{20}$"#, options: .regularExpression) != nil else {
            throw PageError.invalidParams("not a submission id")
        }
        return id
    }

    /// A queue row as the page reads it: the submitter as `{user}`.
    private static func queueRow(_ row: JSONValue) -> JSONValue {
        guard var fields = row.objectValue else { return row }
        if let user = fields["submitter"]?.stringValue { fields["submitter"] = ["user": .string(user)] }
        return .object(fields)
    }
}

/// The native sheets of the community ops: sending an app for review publishes its files, and a
/// reviewer's decision lists or refuses another person's app.
public nonisolated enum AppRegistryPageConfirmations {
    public static func confirmation(op: String, params: JSONValue) -> PageConfirmation? {
        switch op {
        case "cmux.registry.submit":
            let app = params["app"]?.stringValue ?? ""
            return PageConfirmation(kind: .custom, name: String(format: PageStrings.registrySubmitTitle, app),
                                    detail: PageStrings.registrySubmitDetail)
        case "cmux.registry.review.decide":
            let approve = params["decision"]?.stringValue == "approve"
            // Name the exact submission the request decides, never a page-supplied app label.
            let app = params["id"]?.stringValue ?? ""
            return PageConfirmation(kind: .custom, name: String(format: approve ? PageStrings.registryApproveTitle : PageStrings.registryRejectTitle, app),
                                    detail: approve ? PageStrings.registryApproveDetail : nil)
        default:
            return nil
        }
    }
}
