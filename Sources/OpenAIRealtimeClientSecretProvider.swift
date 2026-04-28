import Foundation

struct OpenAIRealtimeSessionConfiguration {
    var model: String = "gpt-realtime-1.5"
    var voice: String = "marin"
    var instructions: String
    var tools: [[String: Any]]

    var sessionPayload: [String: Any] {
        [
            "type": "realtime",
            "model": model,
            "instructions": instructions,
            "output_modalities": ["audio"],
            "audio": [
                "input": [
                    "transcription": [
                        "model": "gpt-4o-transcribe"
                    ],
                    "turn_detection": [
                        "type": "semantic_vad"
                    ]
                ],
                "output": [
                    "voice": voice
                ]
            ],
            "tools": tools,
            "tool_choice": "auto"
        ]
    }
}

enum OpenAIAPIKeyResolver {
    enum ResolverError: Error, LocalizedError {
        case missingKey

        var errorDescription: String? {
            String(
                localized: "voice.error.openAIKeyMissing",
                defaultValue: "OpenAI API key was not found in the environment or ~/.secrets."
            )
        }
    }

    static func resolveAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        secretsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".secrets")
    ) throws -> String {
        if let key = parseAPIKey(from: environment["OPENAI_API_KEY"] ?? "") {
            return key
        }

        let candidateNames = [
            "openai.env",
            "openai-api-key",
            "openai_api_key",
            ".openai",
            "cmux.env",
            "cmuxterm.env",
            "cmuxterm-dev.env"
        ]

        for name in candidateNames {
            let url = secretsDirectory.appendingPathComponent(name)
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  let key = parseAPIKey(from: contents) else {
                continue
            }
            return key
        }

        throw ResolverError.missingKey
    }

    static func parseAPIKey(from text: String) -> String? {
        let trimmed = stripWrappingQuotes(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if looksLikeAPIKey(trimmed) {
            return trimmed
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let prefixes = [
                "OPENAI_API_KEY=",
                "OPENAI_KEY=",
                "OPENAI_TOKEN="
            ]
            for prefix in prefixes where line.hasPrefix(prefix) {
                let value = stripWrappingQuotes(String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines))
                if looksLikeAPIKey(value) {
                    return value
                }
            }
        }

        return nil
    }

    private static func stripWrappingQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func looksLikeAPIKey(_ value: String) -> Bool {
        value.hasPrefix("sk-") || value.hasPrefix("sk_proj-")
    }
}

final class OpenAIRealtimeClientSecretProvider {
    enum ProviderError: Error, LocalizedError {
        case invalidResponse
        case httpFailure(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return String(localized: "voice.error.clientSecretInvalid", defaultValue: "OpenAI did not return a usable client secret.")
            case .httpFailure(let status, let body):
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return String(
                        format: String(
                            localized: "voice.error.clientSecretHTTP",
                            defaultValue: "OpenAI client secret request failed with HTTP %@."
                        ),
                        "\(status)"
                    )
                }
                return String(
                    format: String(
                        localized: "voice.error.clientSecretHTTPWithBody",
                        defaultValue: "OpenAI client secret request failed with HTTP %@: %@"
                    ),
                    "\(status)",
                    trimmed
                )
            }
        }
    }

    private let endpoint = URL(string: "https://api.openai.com/v1/realtime/client_secrets")!
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func createClientSecret(configuration: OpenAIRealtimeSessionConfiguration) async throws -> String {
        let apiKey = try OpenAIAPIKeyResolver.resolveAPIKey()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try VoiceJSON.data(from: ["session": configuration.sessionPayload])

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError.httpFailure(status, body)
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = Self.clientSecretValue(in: object) else {
            throw ProviderError.invalidResponse
        }
        return value
    }

    static func clientSecretValue(in object: [String: Any]) -> String? {
        if let value = object["value"] as? String {
            return value
        }
        if let clientSecret = object["client_secret"] as? [String: Any],
           let value = clientSecret["value"] as? String {
            return value
        }
        if let secret = object["secret"] as? [String: Any],
           let value = secret["value"] as? String {
            return value
        }
        return nil
    }
}
