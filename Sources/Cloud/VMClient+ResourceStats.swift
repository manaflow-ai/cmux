import Foundation

extension VMClient {
    /// All callers share revisioned resource state, including CLI and sidebar reads.
    func stats(id: String) async throws -> VMStats {
        let read = await resourceStats.beginRead(machineID: id)
        do {
            let stats = try await withOperation(.stats, foreground: false) {
                let encodedID = try pathSegment(id, fieldName: "vm id")
                let (data, http) = try await request("GET", path: "/api/vm/\(encodedID)/stats", timeoutSeconds: 30)
                try ensureOK(http, data: data)
                return VMStats(json: try decodeJSONObject(data))
            }
            return await resourceStats.finishRead(read, stats: stats)
        } catch {
            _ = await resourceStats.finishRead(read, stats: nil)
            throw error
        }
    }

    /// Grow a machine's disk through the same resource mutation path.
    func resizeDisk(id: String, diskMb: Int) async throws -> VMStats {
        try await resize(id: id, cpu: nil, memoryMb: nil, diskMb: diskMb)
    }

    /// Invalidate pre-resize polls and publish the provider-confirmed shape to every panel.
    func resize(id: String, cpu: Int?, memoryMb: Int?, diskMb: Int?) async throws -> VMStats {
        let mutation = await resourceStats.beginResize(machineID: id)
        do {
            let stats = try await withOperation(.resize, foreground: true) {
                let encodedID = try pathSegment(id, fieldName: "vm id")
                var body: [String: Any] = [:]
                if let cpu { body["cpu"] = cpu }
                if let memoryMb { body["memoryMb"] = memoryMb }
                if let diskMb { body["storageMb"] = diskMb }
                let (data, http) = try await request(
                    "POST", path: "/api/vm/\(encodedID)/resize", jsonBody: body, timeoutSeconds: 120
                )
                try ensureOK(http, data: data)
                return VMStats(json: try decodeJSONObject(data))
            }
            await resourceStats.finishResize(mutation, stats: stats)
            return stats
        } catch {
            // The provider may have resized before a response was lost. A new
            // stats response must confirm capacity; do not restore the old shape.
            await resourceStats.finishResize(mutation, stats: nil)
            throw error
        }
    }
}
