import Foundation

// MARK: - Errors

enum StatuspageIOFetchError: Error {
    case http(Int)
    case decoding
    case network(Error)
    case invalidHost(String)
}

// MARK: - Fetcher

enum StatuspageIOFetcher {

    private static let session = ProviderHTTP.makeSession(timeout: 5)

    /// Hosts permitted as Statuspage.io API origins. Must be kept in sync with
    /// the `fetchStatus` closures in each registered provider.
    private static let allowedHosts: Set<String> = [
        "status.claude.com",
        "status.openai.com",
    ]

    /// Fetches unresolved incidents from a Statuspage.io-compatible API.
    /// When `componentFilter` is provided, only incidents affecting at least one
    /// of the listed component names are returned.
    static func fetch(host: String, componentFilter: Set<String>? = nil) async throws -> [ProviderIncident] {
        guard !host.contains("/"), !host.contains(":"), allowedHosts.contains(host) else {
            throw StatuspageIOFetchError.invalidHost(host)
        }
        guard let url = URL(string: "https://\(host)/api/v2/incidents.json") else {
            throw StatuspageIOFetchError.decoding
        }

        let json: [String: Any]
        do {
            json = try await ProviderHTTP.getJSONObject(url: url, session: session)
        } catch is CancellationError {
            throw CancellationError()
        } catch ProviderHTTPError.http(let status) {
            throw StatuspageIOFetchError.http(status)
        } catch ProviderHTTPError.badResponse {
            throw StatuspageIOFetchError.decoding
        } catch ProviderHTTPError.network(let underlying) {
            throw StatuspageIOFetchError.network(underlying)
        } catch {
            throw StatuspageIOFetchError.decoding
        }
        guard let incidents = json["incidents"] as? [[String: Any]] else {
            throw StatuspageIOFetchError.decoding
        }

        let closedStatuses: Set<String> = ["resolved", "postmortem", "completed"]
        return incidents.compactMap { dict in
            let status = dict["status"] as? String ?? "unknown"
            guard !closedStatuses.contains(status) else { return nil }
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String else {
                return nil
            }

            if let filter = componentFilter {
                let components = dict["components"] as? [[String: Any]] ?? []
                // The component intersection only applies when the payload
                // attaches a component list; page-wide incidents arrive with an
                // empty components array and should always be surfaced.
                if !components.isEmpty {
                    let componentNames = Set(components.compactMap { $0["name"] as? String })
                    guard !componentNames.isDisjoint(with: filter) else { return nil }
                }
            }

            let impact = dict["impact"] as? String ?? "none"
            let updatedAt = ProviderISO8601DateParser.parse(dict["updated_at"] as? String)
            return ProviderIncident(id: id, name: name, status: status, impact: impact, updatedAt: updatedAt)
        }
    }
}

