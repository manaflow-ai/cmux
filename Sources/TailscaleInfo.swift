import Foundation

/// Detects Tailscale network information for device registration.
enum TailscaleInfo {
    /// Get the Tailscale hostname (e.g., "macbook-pro.tail1234.ts.net").
    /// Returns nil if Tailscale is not running.
    static func hostname() -> String? {
        if let status = runTailscaleStatus() {
            return status
        }
        return nil
    }

    /// Check if Tailscale is available by looking for a 100.x.x.x address.
    static var isAvailable: Bool {
        hostname() != nil
    }

    // MARK: - Private

    private static func runTailscaleStatus() -> String? {
        // Try the CLI path first (installed via Mac App Store or standalone).
        let cliPaths = [
            "/usr/local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ]

        for cliPath in cliPaths {
            guard FileManager.default.isExecutableFile(atPath: cliPath) else { continue }

            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["status", "--json"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                continue
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // The "Self" key contains this machine's info.
            if let selfNode = json["Self"] as? [String: Any],
               let dnsName = selfNode["DNSName"] as? String,
               !dnsName.isEmpty {
                // DNSName has a trailing dot; strip it.
                return dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
            }
        }

        return nil
    }
}
