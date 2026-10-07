import Foundation

/// A private local activity store for event metadata and thumbnails.
///
/// The store keeps searchable metadata free of screen text. Pixels are content
/// addressed files below a 0700 directory and each file is chmod 0600.
public actor AgentActivityStore {
    private let rootURL: URL
    private let eventsURL: URL
    private let blobsURL: URL
    private let fileManager: FileManager
    private let planner: AgentActivityRetentionPlanner
    private var events: [AgentActivityStoredEvent] = []
    private var frames: [AgentActivityStoredFrame] = []

    /// Creates a store below an injected Application Support directory.
    public init(applicationSupportDirectory: URL, profile: String = "default",
                clock: any AgentActivityClock, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        rootURL = applicationSupportDirectory.appendingPathComponent("cmux/cua/activity-\(profile)", isDirectory: true)
        eventsURL = rootURL.appendingPathComponent("events.jsonl")
        blobsURL = rootURL.appendingPathComponent("blobs", isDirectory: true)
        planner = AgentActivityRetentionPlanner(clock: clock)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: blobsURL, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blobsURL.path)
    }

    /// App Support location used by the production composition root.
    public static func applicationSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    /// Appends an event and optionally writes its thumbnail before indexing it.
    @discardableResult
    public func append(_ event: AgentActivityStoredEvent, thumbnail: (blob: String, data: Data, capturedAt: Date)? = nil) throws -> URL? {
        var thumbnailURL: URL?
        if let thumbnail {
            thumbnailURL = blobsURL.appendingPathComponent(thumbnail.blob)
            try thumbnail.data.write(to: thumbnailURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: thumbnailURL.path)
            frames.append(AgentActivityStoredFrame(blob: thumbnail.blob, capturedAt: thumbnail.capturedAt))
        }
        let line = try JSONEncoder().encode(EventRecord(event: event))
        var payload = line
        payload.append(0x0A)
        if fileManager.fileExists(atPath: eventsURL.path) {
            let handle = try FileHandle(forWritingTo: eventsURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
            try handle.close()
        } else {
            try payload.write(to: eventsURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: eventsURL.path)
        }
        events.append(event)
        return thumbnailURL
    }

    /// Applies the injected-clock retention policy and removes expired files.
    @discardableResult
    public func prune() throws -> AgentActivityRetentionPlan {
        let plan = planner.plan(events: events, frames: frames)
        for blob in plan.frameBlobs {
            let url = blobsURL.appendingPathComponent(blob)
            try? fileManager.removeItem(at: url)
        }
        let removed = Set(plan.eventIDs)
        events.removeAll { removed.contains($0.id) }
        frames.removeAll { plan.frameBlobs.contains($0.blob) }
        if !removed.isEmpty {
            var data = Data()
            for event in events {
                data.append(try JSONEncoder().encode(EventRecord(event: event)))
                data.append(0x0A)
            }
            try data.write(to: eventsURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: eventsURL.path)
        }
        return plan
    }

    /// The root directory, useful for diagnostics without exposing pixels.
    public func storageURL() -> URL { rootURL }

    private struct EventRecord: Codable {
        let id: String
        let at: Date
        let frameBlobs: [String]
        init(event: AgentActivityStoredEvent) { id = event.id; at = event.at; frameBlobs = event.frameBlobs }
    }
}
