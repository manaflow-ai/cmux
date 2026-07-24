import CmuxSimulator
import Foundation

extension SimulatorPrivatePrivacyAdapter {
    static let maximumUnfilteredApplications = 256

    func setTCC(
        deviceIdentifier: String,
        bundleIdentifier: String,
        action: SimulatorPrivacyAction,
        service: SimulatorPrivacyService
    ) async throws {
        guard let sql = tccMutationSQL(
            service: service,
            action: action,
            bundleIdentifier: bundleIdentifier
        ) else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "The requested permission is not supported by the isolated TCC adapter."
            )
        }
        let databaseURL = simulatorLibrary(deviceIdentifier: deviceIdentifier)
            .appendingPathComponent("TCC/TCC.db")
        guard fileSystem.isReadableFile(atPath: databaseURL.path) else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "The Simulator TCC database is unavailable; wait for the device to finish booting."
            )
        }
        try await runSQLite(databaseURL: databaseURL, sql: sql)
    }

    func setTCCWithoutMutationGate(
        deviceIdentifier: String,
        bundleIdentifier: String,
        action: SimulatorPrivacyAction,
        service: SimulatorPrivacyService
    ) async throws {
        guard simulatorPrivacyIdentifierIsSafe(deviceIdentifier),
              simulatorPrivacyIdentifierIsSafe(bundleIdentifier) else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "Permission mutation rejected an invalid device or bundle identifier."
            )
        }
        try await setTCC(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier,
            action: action,
            service: service
        )
    }

    func tccMutationSQL(
        service: SimulatorPrivacyService,
        action: SimulatorPrivacyAction,
        bundleIdentifier: String
    ) -> String? {
        let definition: (name: String, authVersion: Int)? = switch service {
        case .camera: ("kTCCServiceCamera", 1)
        case .photosLimited: ("kTCCServicePhotos", 2)
        case .speech: ("kTCCServiceSpeechRecognition", 1)
        case .faceID: ("kTCCServiceFaceID", 1)
        case .userTracking: ("kTCCServiceUserTracking", 1)
        case .homeKit: ("kTCCServiceWillow", 1)
        default: nil
        }
        guard let definition else { return nil }
        let authValue: Int? = switch action {
        case .grant: service == .photosLimited ? 3 : 2
        case .revoke: 0
        case .reset: nil
        }
        var statements = [
            "BEGIN IMMEDIATE;",
            "DELETE FROM access WHERE service='\(definition.name)' " +
                "AND client='\(bundleIdentifier)' AND client_type=0;",
        ]
        if let authValue {
            statements.append(
                "INSERT INTO access " +
                    "(service, client, client_type, auth_value, auth_reason, auth_version, flags) " +
                    "VALUES ('\(definition.name)', '\(bundleIdentifier)', 0, \(authValue), 2, " +
                    "\(definition.authVersion), 0);"
            )
        }
        statements.append("COMMIT;")
        return statements.joined()
    }

    func readTCCRows(
        databaseURL: URL,
        bundleIdentifier: String
    ) async throws -> [String: Int] {
        let sql = "SELECT service, auth_value FROM access WHERE client='\(bundleIdentifier)';"
        let result = try await subprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: sqliteArguments(databaseURL: databaseURL, sql: sql)
        )
        guard result.status == 0 else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                result.standardError.isEmpty
                    ? "The Simulator TCC readback failed."
                    : result.standardError
            )
        }
        var rows: [String: Int] = [:]
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard fields.count == 2, let value = Int(fields[1]) else { continue }
            rows[fields[0]] = value
        }
        return rows
    }

    func readTCCApplicationRows(
        databaseURL: URL
    ) async throws -> SimulatorTCCApplicationReadback {
        let databaseServices = Array(Set(Self.tccServiceMappings.map(\.databaseName))).sorted()
        let quotedServices = databaseServices.map { "'\($0)'" }.joined(separator: ",")
        let candidateLimit = Self.maximumUnfilteredApplications + 1
        let sql = """
        WITH clients AS (
          SELECT DISTINCT client FROM access
          WHERE client_type=0
            AND service IN (\(quotedServices))
            AND length(CAST(client AS BLOB)) BETWEEN 1 AND 255
            AND client NOT GLOB '*[^A-Za-z0-9.-]*'
            AND substr(client, 1, 1) GLOB '[A-Za-z0-9]'
          ORDER BY client
          LIMIT \(candidateLimit)
        )
        SELECT access.client, access.service, MAX(access.auth_value)
        FROM access JOIN clients ON clients.client=access.client
        WHERE access.client_type=0 AND access.service IN (\(quotedServices))
        GROUP BY access.client, access.service
        ORDER BY access.client, access.service;
        """
        let result = try await subprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: sqliteArguments(databaseURL: databaseURL, sql: sql)
        )
        guard result.status == 0 else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                result.standardError.isEmpty
                    ? "The Simulator TCC application readback failed."
                    : result.standardError
            )
        }
        return parseTCCApplicationRows(result.standardOutput)
    }

    func parseTCCApplicationRows(
        _ output: String
    ) -> SimulatorTCCApplicationReadback {
        let supportedServices = Set(Self.tccServiceMappings.map(\.databaseName))
        let candidateLimit = Self.maximumUnfilteredApplications + 1
        var bundleIdentifiers: [String] = []
        var rowsByBundleIdentifier: [String: [String: Int]] = [:]

        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "|", maxSplits: 2).map(String.init)
            guard fields.count == 3,
                  simulatorPrivacyIdentifierIsSafe(fields[0]),
                  supportedServices.contains(fields[1]),
                  let value = Int(fields[2]) else { continue }
            if rowsByBundleIdentifier[fields[0]] == nil {
                guard bundleIdentifiers.count < candidateLimit else { continue }
                bundleIdentifiers.append(fields[0])
                rowsByBundleIdentifier[fields[0]] = [:]
            }
            rowsByBundleIdentifier[fields[0]]?[fields[1]] = value
        }

        return SimulatorTCCApplicationReadback(
            applications: bundleIdentifiers.map {
                SimulatorTCCApplicationRows(
                    bundleIdentifier: $0,
                    services: rowsByBundleIdentifier[$0] ?? [:]
                )
            },
            isTruncated: bundleIdentifiers.count > Self.maximumUnfilteredApplications
        )
    }

    func applyTCCRows(
        _ rows: [String: Int],
        to authorizations: inout [SimulatorPrivacyService: SimulatorPrivacyAuthorization]
    ) {
        for (service, databaseName) in Self.tccServiceMappings {
            guard let value = rows[databaseName] else {
                authorizations[service] = .notDetermined
                continue
            }
            authorizations[service] = switch value {
            case 0: .denied
            case 2: .granted
            case 3: .limited
            default: .unknown
            }
        }
    }

    static let tccServiceMappings: [(service: SimulatorPrivacyService, databaseName: String)] = [
        (.calendar, "kTCCServiceCalendar"),
        (.contacts, "kTCCServiceAddressBook"),
        (.photos, "kTCCServicePhotos"),
        (.photosLimited, "kTCCServicePhotos"),
        (.photosAdd, "kTCCServicePhotosAdd"),
        (.mediaLibrary, "kTCCServiceMediaLibrary"),
        (.microphone, "kTCCServiceMicrophone"),
        (.motion, "kTCCServiceMotion"),
        (.reminders, "kTCCServiceReminders"),
        (.siri, "kTCCServiceSiri"),
        (.camera, "kTCCServiceCamera"),
        (.speech, "kTCCServiceSpeechRecognition"),
        (.faceID, "kTCCServiceFaceID"),
        (.userTracking, "kTCCServiceUserTracking"),
        (.homeKit, "kTCCServiceWillow"),
    ]

    func runSQLite(databaseURL: URL, sql: String) async throws {
        let result = try await subprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: sqliteArguments(databaseURL: databaseURL, sql: sql)
        )
        guard result.status == 0 else {
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                detail.isEmpty ? "The Simulator TCC database update failed." : detail
            )
        }
    }

    func sqliteArguments(databaseURL: URL, sql: String) -> [String] {
        [
            "-cmd",
            ".timeout \(sqliteBusyTimeoutMilliseconds)",
            databaseURL.path,
            sql,
        ]
    }
}
