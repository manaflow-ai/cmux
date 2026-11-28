import Foundation
import Observation

// cmux Dev's Try a pull request picker (Settings > Developer; cmuxterm-hq
// docs/design/ios-dev-channels.md, iPhone DEV step 3). The Mac the phone is
// attached to serves `try-pr` (`try-pr-v1`, PROTOCOL.md): it lists the open
// iPhone pull requests with whether each head's cmux Dev is built ahead, and
// installs one with `try.sh N`, which replaces this app. The rules live in
// hostd (`try_pr.rs`) and try.sh; this decodes their frames.

/// One open iPhone pull request as `try.sh list` names it.
public struct TryPullRequest: Identifiable, Hashable, Sendable {
    /// Where its cmux Dev build stands.
    public enum Build: String, Sendable {
        /// Built ahead by the `cmux Dev try build (ahead)` check: installing only downloads it.
        case ahead
        /// The ahead check is queued or running.
        case building
        /// The device app did not build at this head.
        case failed
        /// The Mac already has this head's app.
        case cached
        /// Not built: installing asks the fleet first.
        case none

        public var label: String {
            switch self {
            case .ahead: "Built"
            case .building: "Building"
            case .failed: "Build failed"
            case .cached: "On this Mac"
            case .none: "Not built"
            }
        }

        /// Whether a tap installs without waiting for a build.
        public var ready: Bool { self == .ahead || self == .cached }
    }

    public var number: Int
    public var title: String
    public var author: String
    public var head: String
    public var updatedAt: Date?
    public var draft: Bool
    public var build: Build

    public var id: Int { number }

    public init(number: Int, title: String, author: String = "", head: String = "", updatedAt: Date? = nil,
                draft: Bool = false, build: Build = .none) {
        self.number = number
        self.title = title
        self.author = author
        self.head = head
        self.updatedAt = updatedAt
        self.draft = draft
        self.build = build
    }

    init?(json: [String: Any]) {
        guard let number = json["number"] as? Int, number > 0 else { return nil }
        self.number = number
        title = json["title"] as? String ?? ""
        author = json["author"] as? String ?? ""
        head = json["head"] as? String ?? ""
        updatedAt = (json["updated_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        draft = json["draft"] as? Bool ?? false
        build = (json["build"] as? String).flatMap(Build.init(rawValue:)) ?? Build.none
    }
}

/// `try.sh list`'s answer: the pull requests, or why the Mac could not list them.
public struct TryPullRequestList: Equatable, Sendable {
    public var prs: [TryPullRequest]
    public var error: String?

    public init(prs: [TryPullRequest], error: String? = nil) {
        self.prs = prs
        self.error = error
    }

    /// One `{"op":"list"}` frame (`cmux.ios-try.list.v1`).
    public static func decode(_ data: Data) -> TryPullRequestList? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["prs"] as? [[String: Any]] else { return nil }
        let error = (object["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return TryPullRequestList(prs: rows.compactMap(TryPullRequest.init(json:)), error: error)
    }
}

/// One frame of an install's stream.
public enum TryInstallEvent: Equatable, Sendable {
    /// A line try.sh printed.
    case line(String)
    /// try.sh ended with this exit status (0: installed).
    case done(exit: Int)

    public static func decode(_ data: Data) -> TryInstallEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if object["done"] as? Bool == true { return .done(exit: object["exit"] as? Int ?? -1) }
        if let line = object["line"] as? String { return .line(line) }
        return nil
    }
}

/// The Mac's last install, as `{"op":"status"}` answers it: what the relaunched app shows
/// after an install replaced it (#51721 F3).
public struct TryInstallStatus: Equatable, Sendable {
    public var number: Int
    public var lines: [String]
    /// nil while it still runs.
    public var exit: Int?

    public init(number: Int, lines: [String], exit: Int? = nil) {
        self.number = number
        self.lines = lines
        self.exit = exit
    }

    /// `{"run":{"pr","started_ms","lines","exit"?}|null}`: nil for no install (or a frame that
    /// does not read).
    public static func decode(_ data: Data) -> TryInstallStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let run = object["run"] as? [String: Any],
              let number = run["pr"] as? Int, number > 0 else { return nil }
        let lines = (run["lines"] as? [Any] ?? []).compactMap { $0 as? String }
        return TryInstallStatus(number: number, lines: Array(lines.suffix(TryPullRequestModel.keepLines)),
                                exit: run["exit"] as? Int)
    }
}

/// The Mac side of the picker.
@MainActor
public protocol TryPullRequestService: AnyObject {
    func tryPullRequests(macID: String) async throws -> TryPullRequestList
    /// Starts `try.sh number` on the Mac; the stream ends with `.done` or throws when the channel
    /// closes first (installing replaces this app, so it often does).
    func installPullRequest(macID: String, number: Int) -> AsyncThrowingStream<TryInstallEvent, any Error>
    /// The Mac's last install (`{"op":"status"}`), nil when it ran none.
    func tryInstallStatus(macID: String) async throws -> TryInstallStatus?
}

/// The capability a Mac lists when it serves `try-pr`.
public let tryPullRequestCapability = "try-pr-v1"

/// The picker page's state: the Mac's list and the install in progress.
@MainActor
@Observable
public final class TryPullRequestModel {
    public enum Load: Equatable {
        case loading
        case loaded(TryPullRequestList)
        case failed(String)
        /// The Mac's link is down; the page offers Try Again.
        case unreachable
    }

    public enum Install: Equatable {
        case idle
        case running(number: Int, lines: [String])
        case finished(number: Int, exit: Int, lines: [String])
        case failed(number: Int, message: String, lines: [String])
    }

    public let macID: String
    public private(set) var load: Load = .loading
    public private(set) var install: Install = .idle
    @ObservationIgnored private weak var service: (any TryPullRequestService)?
    /// Lines kept on screen.
    public nonisolated static let keepLines = 8

    public init(macID: String, service: (any TryPullRequestService)?) {
        self.macID = macID
        self.service = service
    }

    public var installing: Bool {
        if case .running = install { return true }
        return false
    }

    public func reload() async {
        guard let service else {
            load = .unreachable
            return
        }
        if case .loaded = load {} else { load = .loading }
        do {
            load = .loaded(try await service.tryPullRequests(macID: macID))
        } catch {
            load = .failed(error.localizedDescription)
        }
    }

    /// After the app was replaced by an install (or the page opens again): show how the Mac's
    /// last install went, and follow it when it still runs (hostd replays its kept lines).
    public func resume() async {
        guard let service, case .idle = install,
              let status = try? await service.tryInstallStatus(macID: macID) else { return }
        guard case .idle = install else { return }
        if let exit = status.exit {
            install = .finished(number: status.number, exit: exit, lines: status.lines)
        } else {
            await start(status.number)
        }
    }

    public func start(_ number: Int) async {
        guard let service, !installing else { return }
        var lines: [String] = []
        install = .running(number: number, lines: lines)
        do {
            for try await event in service.installPullRequest(macID: macID, number: number) {
                switch event {
                case .line(let line):
                    lines.append(line)
                    if lines.count > Self.keepLines { lines.removeFirst(lines.count - Self.keepLines) }
                    install = .running(number: number, lines: lines)
                case .done(let exit):
                    install = .finished(number: number, exit: exit, lines: lines)
                    return
                }
            }
            install = .failed(number: number, message: "The Mac stopped answering before the install ended.", lines: lines)
        } catch {
            install = .failed(number: number, message: error.localizedDescription, lines: lines)
        }
    }
}
