public import Foundation

/// The App's upload of files the person dropped or pasted into a chat: it replies as the page's
/// `chat.upload` call (``AgentPaneReply``).
public typealias AgentPaneUploader = @MainActor (_ files: [AgentPaneUpload]) async -> [String: Any]

public nonisolated struct AgentPaneUploadBatchEntry: Sendable, Equatable {
    public let name: String
    public let size: Int

    public init(name: String, size: Int) {
        self.name = name
        self.size = size
    }
}

/// A gesture authorizes an ordered batch. A live stage retains that authorization through both
/// local staging and remote transfer; only an ownerless batch has an abandonment deadline.
package nonisolated struct AgentPaneUploadBatch: Sendable {
    private var remaining: [AgentPaneUploadBatchEntry]
    private var owners: Set<String> = []
    private var expires: Date
    package static let lifetime: TimeInterval = 10 * 60

    package init(_ manifest: [AgentPaneUploadBatchEntry], now: Date = Date()) {
        remaining = manifest
        expires = now.addingTimeInterval(Self.lifetime)
    }

    package var abandonmentDeadline: Date? { owners.isEmpty ? expires : nil }
    package var isComplete: Bool { remaining.isEmpty && owners.isEmpty }
    package func isAlive(at now: Date = Date()) -> Bool { !owners.isEmpty || expires > now }
    package func accepts(name: String, size: Int, at now: Date = Date()) -> Bool {
        isAlive(at: now) && remaining.first == AgentPaneUploadBatchEntry(name: name, size: size)
    }

    @discardableResult
    package mutating func begin(name: String, size: Int, stage: String, at now: Date = Date()) -> Bool {
        guard accepts(name: name, size: size, at: now), !owners.contains(stage) else { return false }
        remaining.removeFirst()
        owners.insert(stage)
        return true
    }

    package mutating func release(stage: String, at now: Date = Date()) {
        guard owners.remove(stage) != nil, owners.isEmpty else { return }
        expires = now.addingTimeInterval(Self.lifetime)
    }
}

public nonisolated enum AgentPaneUploadStageRequest: Sendable, Equatable {
    case begin(name: String, size: Int, batchToken: String?, batch: [AgentPaneUploadBatchEntry]?)
    case chunk(token: String, offset: Int, data: Data)
    case finish(token: String)
    case cancel(token: String)
}

public typealias AgentPaneUploadStager = @MainActor (_ request: AgentPaneUploadStageRequest, _ sessionId: String?) async -> [String: Any]

/// A file the person dropped or pasted into a chat that the composer can't attach, for the App to
/// send to the chat's Cloud machine (`chat.upload {files: [{name, data}]}`, cmuxterm-hq#1874
/// slice 6). The page reads the bytes (it never learns a dropped file's path); the host takes them
/// only for a chat the App uploads for (``AgentPaneModel/onUpload``) and only with a real gesture in
/// the pane: a key or click, or a native file drop on the page (page script can make neither). Its
/// description and mirror never show the bytes or the name.
public nonisolated struct AgentPaneUpload: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    public var description: String { "<upload \(data.count) bytes>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// The files of `chat.upload`'s params, nil when they break the contract: one or more files,
    /// each with a name a folder holds as one file and base64 bytes, of any size. This one-frame
    /// upload is the older page's; the page streams a file of any size through the staged upload
    /// (``AgentPaneUploadStageRequest``) instead.
    static func files(_ params: [String: Any]?) -> [AgentPaneUpload]? {
        guard let params, Set(params.keys) == ["files"], let list = params["files"] as? [[String: Any]],
              !list.isEmpty else { return nil }
        var files: [AgentPaneUpload] = []
        for item in list {
            guard Set(item.keys) == ["name", "data"], let name = item["name"] as? String, isFileName(name),
                  let text = item["data"] as? String, let data = Data(base64Encoded: text) else { return nil }
            files.append(AgentPaneUpload(name: name, data: data))
        }
        return files
    }

    /// A name a folder holds as one plain file: 1 to 255 UTF-8 bytes, not a dot file (nor `.` or
    /// `..`), no `/`, and no control or bidirectional formatting character.
    static func isFileName(_ name: String) -> Bool {
        guard (1...255).contains(name.utf8.count), !name.hasPrefix("."), !name.contains("/") else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            !(scalar.value < 0x20 || scalar.value == 0x7f || (0x80...0x9f).contains(scalar.value)
                || (0x202a...0x202e).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) || scalar.value == 0x200e || scalar.value == 0x200f)
        }
    }

    /// The reply to the page's upload: only for a chat the App uploads for (asked before the gesture
    /// is used, so another chat's paste keeps its gesture), then only with a real gesture.
    @MainActor static func respond(_ files: [AgentPaneUpload], in model: AgentPaneModel) async -> [String: Any] {
        guard let uploader = model.onUpload?() else { return AgentPaneModel.unsupported("chat.upload") }
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        return await uploader(files)
    }
}
