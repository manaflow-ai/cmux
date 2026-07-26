import Foundation

struct SimulatorLocationRouteRecoveryStore: Sendable {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func save(_ record: SimulatorLocationRouteRecoveryRecord) throws {
        let url = fileURL(deviceIdentifier: record.deviceIdentifier)
        try validate(record, sourceURL: url)
        let fileManager = FileManager()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    func record(deviceIdentifier: String) throws -> SimulatorLocationRouteRecoveryRecord? {
        let url = fileURL(deviceIdentifier: deviceIdentifier)
        guard FileManager().fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(
            SimulatorLocationRouteRecoveryRecord.self,
            from: Data(contentsOf: url)
        )
        try validate(record, sourceURL: url)
        return record
    }

    func records() throws -> [SimulatorLocationRouteRecoveryRecord] {
        let fileManager = FileManager()
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var records: [SimulatorLocationRouteRecoveryRecord] = []
        for url in urls where url.pathExtension == "json" {
            let record = try JSONDecoder().decode(
                SimulatorLocationRouteRecoveryRecord.self,
                from: Data(contentsOf: url)
            )
            try validate(record, sourceURL: url)
            records.append(record)
        }
        return records
    }

    @discardableResult
    func remove(
        deviceIdentifier: String,
        expectedOwnershipToken: UUID
    ) throws -> Bool {
        guard let record = try record(deviceIdentifier: deviceIdentifier),
              record.ownershipToken == expectedOwnershipToken else { return false }
        try FileManager().removeItem(at: fileURL(deviceIdentifier: deviceIdentifier))
        return true
    }

    private func fileURL(deviceIdentifier: String) -> URL {
        directory.appendingPathComponent(hash(deviceIdentifier) + ".json")
    }

    private func validate(
        _ record: SimulatorLocationRouteRecoveryRecord,
        sourceURL: URL
    ) throws {
        guard !record.deviceIdentifier.isEmpty,
              coordinateIsValid(record.initialCoordinate),
              routeStateIsValid(record.state),
              processIdentityIsValid(record.ownerProcessIdentity),
              sourceURL.standardizedFileURL == fileURL(
                  deviceIdentifier: record.deviceIdentifier
              ).standardizedFileURL
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private func processIdentityIsValid(_ identity: SimulatorProcessIdentity) -> Bool {
        identity.pid > 0
            && identity.startSeconds > 0
            && (0..<1_000_000).contains(identity.startMicroseconds)
    }

    private func routeStateIsValid(_ state: SimulatorLocationRouteRecoveryState) -> Bool {
        let route: SimulatorLocationRoute
        let minimumWaypointCount: Int
        switch state {
        case let .running(value, startedAt):
            guard startedAt.timeIntervalSinceReferenceDate.isFinite else { return false }
            route = value
            minimumWaypointCount = 2
        case let .paused(value):
            route = value
            minimumWaypointCount = 1
        }
        let durationIsValid = route.waypoints.count == 1
            || route.estimatedDuration?.isFinite == true
        return route.waypoints.count >= minimumWaypointCount
            && route.waypoints.allSatisfy(coordinateIsValid)
            && route.speed.isFinite
            && route.speed > 0
            && durationIsValid
            && route.updateDistance.map { $0.isFinite && $0 > 0 } != false
            && route.updateInterval.map { $0.isFinite && $0 > 0 } != false
    }

    private func coordinateIsValid(_ coordinate: SimulatorLocationCoordinate) -> Bool {
        coordinate.latitude.isFinite
            && coordinate.longitude.isFinite
            && (-90...90).contains(coordinate.latitude)
            && (-180...180).contains(coordinate.longitude)
    }

    private func hash(_ value: String) -> String {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x9e3779b97f4a7c15
        for byte in value.utf8 {
            first ^= UInt64(byte)
            first &*= 0x100000001b3
            second ^= UInt64(byte) &+ 0x9d
            second = (second << 7) | (second >> 57)
            second &*= 0x9e3779b185ebca87
        }
        return String(format: "%016llx%016llx", first, second)
    }
}
