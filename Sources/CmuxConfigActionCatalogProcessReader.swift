import Darwin
import Foundation

struct CmuxConfigActionCatalogProcessReader: CmuxConfigActionCatalogRawReading {
    typealias LaunchProvider = @Sendable (
        CmuxConfigActionCatalogRawReadRequest
    ) -> LaunchSpecification?

    static let shared = CmuxConfigActionCatalogProcessReader()
    static let helperCommand = "__action-catalog-read-v1"
    static let defaultMaximumConfigBytes = 1 << 20
    static let maximumAllowedConfigBytes = 4 << 20
    private static let bundledLaunchProvider: LaunchProvider = { request in
        bundledLaunchSpecification(request: request)
    }

    private let timeout: TimeInterval
    private let terminationGrace: TimeInterval
    private let postKillHandoffDelay: TimeInterval
    private let launchProvider: LaunchProvider
    private let timing: Timing
    private let codec: CmuxConfigActionCatalogFrameCodec
    private let processOperations: ProcessOperations
    private let quarantine: CmuxConfigActionCatalogProcessQuarantine

    init(
        timeout: TimeInterval = 2,
        terminationGrace: TimeInterval = 0.2,
        postKillHandoffDelay: TimeInterval = 0.2,
        timing: Timing = .continuous,
        codec: CmuxConfigActionCatalogFrameCodec = .shared,
        processOperations: ProcessOperations = .live,
        quarantine: CmuxConfigActionCatalogProcessQuarantine = .shared,
        launchProvider: @escaping LaunchProvider =
            CmuxConfigActionCatalogProcessReader.bundledLaunchProvider
    ) {
        self.timeout = max(0.01, timeout)
        self.terminationGrace = max(0.01, terminationGrace)
        self.postKillHandoffDelay = max(0.01, postKillHandoffDelay)
        self.timing = timing
        self.codec = codec
        self.processOperations = processOperations
        self.quarantine = quarantine
        self.launchProvider = launchProvider
    }

    func read(
        request: CmuxConfigActionCatalogRawReadRequest
    ) async -> CmuxConfigActionCatalogRawReadResponse? {
        guard !Task.isCancelled,
              request.maximumConfigBytes > 0,
              request.maximumConfigBytes <= Self.maximumAllowedConfigBytes,
              let launch = launchProvider(request) else {
            return nil
        }
        let quarantineKey = request.globalConfigPath + "\u{0}" + (request.directory ?? "<global>")
        let quarantineLane: CmuxConfigActionCatalogProcessQuarantineLane =
            request.directory == nil ? .global : .general
        guard let quarantineLease = await quarantine.reserve(
            key: quarantineKey,
            lane: quarantineLane
        ) else {
            return nil
        }
        let maximumFrameBytes = CmuxConfigActionCatalogFrameCodec.magic.count
            + (3 * 5)
            + CmuxConfigActionCatalogFrameCodec.maximumPathBytes
            + (2 * request.maximumConfigBytes)
        let session = CmuxConfigActionCatalogProcessSession(
            launch: launch,
            timeout: timeout,
            terminationGrace: terminationGrace,
            postKillHandoffDelay: postKillHandoffDelay,
            maximumOutputBytes: maximumFrameBytes,
            timing: timing,
            processOperations: processOperations,
            quarantine: quarantine,
            quarantineLease: quarantineLease
        )
        let result = await session.run()
        guard case .completed(let frame) = result else { return nil }
        await quarantine.release(quarantineLease)
        guard let frame, !Task.isCancelled,
              let response = codec.decode(
                frame,
                maximumConfigBytes: request.maximumConfigBytes
              ), Self.valid(response: response, for: request) else {
            return nil
        }
        return response
    }

    private static func bundledLaunchSpecification(
        request: CmuxConfigActionCatalogRawReadRequest
    ) -> LaunchSpecification? {
        guard let executablePath = Bundle.main.resourceURL?
            .appendingPathComponent("bin/cmux", isDirectory: false).path else {
            return nil
        }
        return LaunchSpecification(
            executablePath: executablePath,
            arguments: [
                executablePath,
                helperCommand,
                request.directory ?? "",
                request.globalConfigPath,
                String(request.maximumConfigBytes),
            ],
            environment: [
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin",
            ]
        )
    }

    private static func valid(
        response: CmuxConfigActionCatalogRawReadResponse,
        for request: CmuxConfigActionCatalogRawReadRequest
    ) -> Bool {
        guard response.global.data.count <= request.maximumConfigBytes else { return false }
        if let local = response.local, local.data.count > request.maximumConfigBytes {
            return false
        }
        guard let directory = request.directory else {
            return response.localPath == nil && response.local == nil
        }
        guard let localPath = response.localPath,
              response.local != nil,
              (localPath as NSString).isAbsolutePath else {
            return false
        }
        return allowedLocalPaths(startingFrom: directory).contains(localPath)
    }

    private static func allowedLocalPaths(startingFrom directory: String) -> Set<String> {
        var current = directory
        var paths = Set<String>()
        while true {
            paths.insert(
                ((current as NSString).appendingPathComponent(".cmux") as NSString)
                    .appendingPathComponent("cmux.json")
            )
            paths.insert((current as NSString).appendingPathComponent("cmux.json"))
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return paths
    }
}
