import Foundation

extension RemoteHookInvocationBridge {
    // Fixed slots plus the per-transfer caps bound aggregate staging to 68 MiB.
    func beginTransfer(_ invocation: RemoteHookInvocation) throws -> String {
        try FileManager.default.createDirectory(
            at: transferRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: transferRoot.path
        )
        let metadata = RemoteHookTransferMetadata(
            arguments: invocation.arguments,
            environment: invocation.environment
        )
        let metadataData = try JSONEncoder().encode(metadata)
        guard metadataData.count <= maximumTransferMetadataBytes else {
            throw invalidTransferError()
        }

        for slot in 0 ..< maximumConcurrentTransfers {
            let slotDirectory = transferRoot.appendingPathComponent("slot-\(slot)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: slotDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                if FileManager.default.fileExists(atPath: slotDirectory.path) {
                    continue
                }
                throw error
            }

            let uuid = UUID().uuidString
            let directory = slotDirectory.appendingPathComponent(uuid, isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                try writePrivate(metadataData, to: directory.appendingPathComponent("metadata.json"))
                try writePrivate(Data(), to: directory.appendingPathComponent("stdin"))
                return "\(slot):\(uuid)"
            } catch {
                try? FileManager.default.removeItem(at: slotDirectory)
                throw error
            }
        }

        throw bridgeError(
            "resource_exhausted",
            key: "socket.hooks.remoteBridge.tooManyTransfers",
            fallback: "Too many remote hook payload transfers are active."
        )
    }

    func append(_ chunk: Data, toTransfer transferID: String) throws {
        let directory = try existingTransferDirectory(for: transferID)
        let inputURL = directory.appendingPathComponent("stdin")
        let inputHandle = try FileHandle(forWritingTo: inputURL)
        defer { try? inputHandle.close() }
        let currentSize = try inputHandle.seekToEnd()
        guard currentSize <= UInt64(maximumInputBytes - chunk.count) else {
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
            throw invalidTransferError()
        }
        try inputHandle.write(contentsOf: chunk)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: directory.deletingLastPathComponent().path
        )
    }

    func takeTransfer(_ transferID: String) throws -> RemoteHookInvocation {
        let directory = try existingTransferDirectory(for: transferID)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let metadataData = try boundedTransferData(
            at: directory.appendingPathComponent("metadata.json"),
            maximumBytes: maximumTransferMetadataBytes
        )
        let input = try boundedTransferData(
            at: directory.appendingPathComponent("stdin"),
            maximumBytes: maximumInputBytes
        )
        let metadata = try JSONDecoder().decode(RemoteHookTransferMetadata.self, from: metadataData)
        try validateInputSize(input.count, arguments: metadata.arguments)
        return RemoteHookInvocation(arguments: metadata.arguments, environment: metadata.environment, input: input)
    }

    func removeStaleTransfers(now: Date = Date()) {
        let fileManager = FileManager.default
        guard let slots = try? fileManager.contentsOfDirectory(
            at: transferRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for slot in slots where slot.lastPathComponent.hasPrefix("slot-") {
            guard let modified = try? slot.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate,
                  now.timeIntervalSince(modified) >= staleTransferAge else { continue }
            try? fileManager.removeItem(at: slot)
        }
    }

    private func existingTransferDirectory(for transferID: String) throws -> URL {
        let components = transferID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2,
              let slot = Int(components[0]),
              (0 ..< maximumConcurrentTransfers).contains(slot),
              let uuid = UUID(uuidString: String(components[1])),
              uuid.uuidString == components[1].uppercased() else {
            throw invalidTransferError()
        }
        let slotDirectory = transferRoot.appendingPathComponent("slot-\(slot)", isDirectory: true)
        let directory = slotDirectory.appendingPathComponent(uuid.uuidString, isDirectory: true)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw invalidTransferError()
        }
        return directory
    }

    private func boundedTransferData(at url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= maximumBytes else {
            throw invalidTransferError()
        }
        return try Data(contentsOf: url)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func invalidTransferError() -> RemoteHookInvocationBridgeError {
        bridgeError(
            "invalid_params",
            key: "socket.hooks.remoteBridge.invalidTransfer",
            fallback: "Remote hook payload transfer is missing or too large."
        )
    }
}
