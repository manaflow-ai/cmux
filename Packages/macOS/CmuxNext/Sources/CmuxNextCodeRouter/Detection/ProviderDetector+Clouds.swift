import Foundation

// Gemini, Amazon Bedrock, Google Vertex AI and GitHub Copilot.
extension ProviderDetector {
    /// Gemini CLI: an API key, or its Google sign-in (`~/.gemini/oauth_creds.json`);
    /// the active account email is in `~/.gemini/google_accounts.json`.
    func detectGemini() -> ProviderDetection {
        let keys = detectAPIKey(.gemini)
        let dir = environment.home.appendingPathComponent(".gemini", isDirectory: true)
        let creds = dir.appendingPathComponent("oauth_creds.json")
        guard environment.files.exists(creds) else { return keys }
        let accounts = environment.jsonObject(at: dir.appendingPathComponent("google_accounts.json"))
        return ProviderDetection(provider: .gemini, status: .signedIn, account: account(.gemini, accounts?["active"] as? String),
                                 sources: keys.sources + [.file(environment.display(creds))])
    }

    /// Bedrock: AWS keys or a Bedrock API key in the environment, or named
    /// profiles in the shared AWS files. Only section names are read.
    func detectBedrock() -> ProviderDetection {
        var sources: [DetectionSource] = ["AWS_BEARER_TOKEN_BEDROCK", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]
            .filter { environment.value($0) != nil }.map(DetectionSource.environment)
        var profiles: [String] = []
        let aws = environment.home.appendingPathComponent(".aws", isDirectory: true)
        let files = [
            environment.value("AWS_SHARED_CREDENTIALS_FILE").map { URL(fileURLWithPath: environment.expand($0)) }
                ?? aws.appendingPathComponent("credentials"),
            environment.value("AWS_CONFIG_FILE").map { URL(fileURLWithPath: environment.expand($0)) }
                ?? aws.appendingPathComponent("config"),
        ]
        for file in files {
            guard let data = environment.files.data(at: file), let text = String(data: data, encoding: .utf8) else { continue }
            let names = Self.iniProfiles(text)
            guard !names.isEmpty else { continue }
            sources.append(.file(environment.display(file)))
            profiles += names.filter { !profiles.contains($0) }
        }
        let selected = environment.value("AWS_PROFILE") ?? (profiles.contains("default") ? "default" : profiles.first)
        return ProviderDetection(provider: .bedrock, status: sources.isEmpty ? .missing : .signedIn,
                                 detail: selected.map { "profile \($0)" }, plan: environment.value("AWS_REGION"), sources: sources)
    }

    /// `[default]`, `[profile work]` and `[work]` section names; `[sso-session …]` is not a profile.
    static func iniProfiles(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), line.hasSuffix("]") else { return nil }
            let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("sso-session") || name.hasPrefix("services") { return nil }
            let profile = name.hasPrefix("profile ") ? String(name.dropFirst(8)).trimmingCharacters(in: .whitespaces) : name
            return profile.isEmpty ? nil : profile
        }
    }

    /// Vertex AI: `$GOOGLE_APPLICATION_CREDENTIALS`, or gcloud's application
    /// default credentials. Shows the credential type, or the service
    /// account as an ``AccountLabel`` when there is one.
    func detectVertex() -> ProviderDetection {
        let file: URL
        if let path = environment.value("GOOGLE_APPLICATION_CREDENTIALS") {
            file = URL(fileURLWithPath: environment.expand(path))
        } else {
            file = environment.directory("CLOUDSDK_CONFIG", fallback: ".config/gcloud")
                .appendingPathComponent("application_default_credentials.json")
        }
        guard environment.files.exists(file) else { return .missing(.vertex) }
        let source = DetectionSource.file(environment.display(file))
        guard let object = environment.jsonObject(at: file), let type = object["type"] as? String else {
            return ProviderDetection(provider: .vertex, status: .unknown, sources: [source])
        }
        let project = environment.value("GOOGLE_CLOUD_PROJECT") ?? environment.value("ANTHROPIC_VERTEX_PROJECT_ID")
            ?? (object["quota_project_id"] as? String)
        let serviceAccount = type == "service_account" ? account(.vertex, object["client_email"] as? String, plan: project) : nil
        return ProviderDetection(provider: .vertex, status: .signedIn, account: serviceAccount,
                                 detail: serviceAccount == nil ? type : nil, plan: project, sources: [source])
    }

    /// GitHub Copilot: the editor plugins' `apps.json` / `hosts.json` under
    /// `$XDG_CONFIG_HOME/github-copilot`. The GitHub login (the `user`
    /// field) becomes an ``AccountLabel``.
    func detectCopilot() -> ProviderDetection {
        let dir = environment.directory("XDG_CONFIG_HOME", fallback: ".config").appendingPathComponent("github-copilot", isDirectory: true)
        for name in ["apps.json", "hosts.json"] {
            let file = dir.appendingPathComponent(name)
            guard environment.files.exists(file) else { continue }
            let source = DetectionSource.file(environment.display(file))
            guard let object = environment.jsonObject(at: file) else {
                return ProviderDetection(provider: .copilot, status: .unknown, sources: [source])
            }
            let user = object.keys.sorted().lazy.compactMap { (object[$0] as? [String: Any])?["user"] as? String }.first
            return ProviderDetection(provider: .copilot, status: object.isEmpty ? .missing : .signedIn,
                                     account: account(.copilot, user), sources: [source])
        }
        return .missing(.copilot)
    }
}
