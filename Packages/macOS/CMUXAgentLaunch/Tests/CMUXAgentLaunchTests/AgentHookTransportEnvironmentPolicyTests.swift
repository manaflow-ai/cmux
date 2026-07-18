import CMUXAgentLaunch
import Foundation
import Testing

@Suite("Agent hook transport environment policy")
struct AgentHookTransportEnvironmentPolicyTests {
    @Test("Preserves routing and every auto-naming backend")
    func preservesAutoNamingInputsOnly() {
        let partitioned = partition([
            "CMUX_SOCKET_PATH": "/tmp/cmux.sock",
            "CMUX_SURFACE_ID": "surface:1",
            "CMUX_CUSTOM_CLAUDE_PATH": "/tmp/Claude Code/bin/claude",
            "CMUX_AGENT_HOOK_DELIVERY_ID": "transport-only-id",
            "CMUX_SOCKET_CAPABILITY": "must-not-persist",
            "CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP": "1",
            "CMUX_AGENT_HOOK_DELIVERY_SUPERVISOR_PID": "4242",
            "ANTHROPIC_API_KEY": "anthropic-secret",
            "CLAUDE_CODE_USE_VERTEX": "1",
            "AWS_PROFILE": "bedrock-profile",
            "AWS_SECRET_ACCESS_KEY": "aws-secret",
            "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/gcp.json",
            "OPENAI_API_KEY": "openai-secret",
            "XAI_API_KEY": "grok-secret",
            "XAI_BASE_URL": "https://xai.example.test/v1",
            "GEMINI_API_KEY": "gemini-secret",
            "OPENROUTER_API_KEY": "openrouter-secret",
            "CUSTOM_AUTH_TOKEN": "custom-auth-secret",
            "CUSTOM_ACCESS_TOKEN": "custom-access-secret",
            "CUSTOM_CLIENT_SECRET": "custom-client-secret",
            "HTTPS_PROXY": "http://127.0.0.1:8080",
            "GROK_HOME": "/tmp/grok",
            "OPENCODE_CONFIG_DIR": "/tmp/opencode",
            "PI_CONFIG_DIR": "/tmp/pi",
            "UNRELATED_SECRET": "must-not-persist",
        ])

        #expect(partitioned.durable["CMUX_SOCKET_PATH"] == "/tmp/cmux.sock")
        #expect(partitioned.durable["CMUX_SURFACE_ID"] == "surface:1")
        #expect(partitioned.durable["CMUX_CUSTOM_CLAUDE_PATH"] == "/tmp/Claude Code/bin/claude")
        #expect(partitioned.durable["CLAUDE_CODE_USE_VERTEX"] == "1")
        #expect(partitioned.durable["AWS_PROFILE"] == "bedrock-profile")
        #expect(partitioned.durable["HTTPS_PROXY"] == "http://127.0.0.1:8080")
        #expect(partitioned.durable["XAI_BASE_URL"] == "https://xai.example.test/v1")
        #expect(partitioned.durable["GROK_HOME"] == "/tmp/grok")
        #expect(partitioned.durable["OPENCODE_CONFIG_DIR"] == "/tmp/opencode")
        #expect(partitioned.durable["PI_CONFIG_DIR"] == "/tmp/pi")

        #expect(partitioned.ephemeral["ANTHROPIC_API_KEY"] == "anthropic-secret")
        #expect(partitioned.ephemeral["AWS_SECRET_ACCESS_KEY"] == "aws-secret")
        #expect(partitioned.durable["GOOGLE_APPLICATION_CREDENTIALS"] == "/tmp/gcp.json")
        #expect(partitioned.ephemeral["OPENAI_API_KEY"] == "openai-secret")
        #expect(partitioned.ephemeral["XAI_API_KEY"] == "grok-secret")
        #expect(partitioned.ephemeral["GEMINI_API_KEY"] == "gemini-secret")
        #expect(partitioned.ephemeral["OPENROUTER_API_KEY"] == "openrouter-secret")
        #expect(partitioned.ephemeral["CUSTOM_AUTH_TOKEN"] == "custom-auth-secret")
        #expect(partitioned.ephemeral["CUSTOM_ACCESS_TOKEN"] == "custom-access-secret")
        #expect(partitioned.ephemeral["CUSTOM_CLIENT_SECRET"] == "custom-client-secret")

        let selected = partitioned.merged
        #expect(selected["CMUX_AGENT_HOOK_DELIVERY_ID"] == nil)
        #expect(selected["CMUX_SOCKET_CAPABILITY"] == nil)
        #expect(selected["CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP"] == nil)
        #expect(selected["CMUX_AGENT_HOOK_DELIVERY_SUPERVISOR_PID"] == nil)
        #expect(selected["UNRELATED_SECRET"] == nil)
    }

    @Test("Scrubs legacy per-attempt transport ownership")
    func scrubsLegacyPerAttemptTransportOwnership() {
        let policy = AgentHookTransportEnvironmentPolicy()
        let durable = policy.durableEnvironmentForPersistence(
            from: [
                "CMUX_AGENT_HOOK_DELIVERY_ID": "legacy-delivery",
                "CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP": "111",
                "CMUX_AGENT_HOOK_DELIVERY_SUPERVISOR_PID": "222",
                "CMUX_SOCKET_CAPABILITY": "legacy-capability",
                "CMUX_FUTURE_ROUTE": "preserved-routing-value",
            ],
            hookAgentKind: "codex"
        )

        #expect(durable["CMUX_AGENT_HOOK_DELIVERY_ID"] == nil)
        #expect(durable["CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP"] == nil)
        #expect(durable["CMUX_AGENT_HOOK_DELIVERY_SUPERVISOR_PID"] == nil)
        #expect(durable["CMUX_SOCKET_CAPABILITY"] == nil)
        #expect(durable["CMUX_FUTURE_ROUTE"] == "preserved-routing-value")
    }

    @Test("Keeps credential values out of durable storage")
    func keepsCredentialValuesEphemeral() {
        let partitioned = partition([
            "AWS_CONTAINER_AUTHORIZATION_TOKEN": "ecs-authorization-secret",
            "AWS_SECURITY_TOKEN": "aws-security-secret",
            "AWS_BEARER_TOKEN_BEDROCK": "bedrock-bearer-secret",
            "OPENAI_ADMIN_KEY": "openai-admin-secret",
            "OPENAI_BEARER_TOKEN": "openai-bearer-secret",
            "HTTPS_PROXY": "https://proxy-user:proxy-password@proxy.example.test:8443",
            "ANTHROPIC_BASE_URL": "https://anthropic-user:anthropic-password@api.example.test/v1",
            "OPENAI_BASE_URL": "https://api.example.test/v1?access_token=query-secret",
            "AWS_CONFIG_FILE": "/tmp/aws-config",
            "AWS_SHARED_CREDENTIALS_FILE": "/tmp/aws-credentials",
            "AWS_WEB_IDENTITY_TOKEN_FILE": "/tmp/aws-web-identity-token",
            "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/google-credentials.json",
            "XAI_BASE_URL": "https://api.x.ai/v1",
            "HTTP_PROXY": "http://127.0.0.1:8080",
        ])

        let expectedEphemeral: [String: String] = [
            "AWS_CONTAINER_AUTHORIZATION_TOKEN": "ecs-authorization-secret",
            "AWS_SECURITY_TOKEN": "aws-security-secret",
            "AWS_BEARER_TOKEN_BEDROCK": "bedrock-bearer-secret",
            "OPENAI_ADMIN_KEY": "openai-admin-secret",
            "OPENAI_BEARER_TOKEN": "openai-bearer-secret",
            "HTTPS_PROXY": "https://proxy-user:proxy-password@proxy.example.test:8443",
            "ANTHROPIC_BASE_URL": "https://anthropic-user:anthropic-password@api.example.test/v1",
            "OPENAI_BASE_URL": "https://api.example.test/v1?access_token=query-secret",
        ]
        for (key, value) in expectedEphemeral {
            #expect(partitioned.ephemeral[key] == value)
            #expect(partitioned.durable[key] == nil)
        }

        #expect(partitioned.durable["AWS_CONFIG_FILE"] == "/tmp/aws-config")
        #expect(partitioned.durable["AWS_SHARED_CREDENTIALS_FILE"] == "/tmp/aws-credentials")
        #expect(partitioned.durable["AWS_WEB_IDENTITY_TOKEN_FILE"] == "/tmp/aws-web-identity-token")
        #expect(partitioned.durable["GOOGLE_APPLICATION_CREDENTIALS"] == "/tmp/google-credentials.json")
        #expect(partitioned.durable["XAI_BASE_URL"] == "https://api.x.ai/v1")
        #expect(partitioned.durable["HTTP_PROXY"] == "http://127.0.0.1:8080")
    }

    @Test("Sanitizes durable launch argv while preserving the live capture")
    func sanitizesDurableLaunchArguments() throws {
        let rawArguments = [
            "/usr/local/bin/codex",
            "--remote", "wss://relay.example.test/session?token=argv-secret",
            "--model", "gpt-5.4",
            "initial prompt secret",
        ]
        let raw = encodeArguments(rawArguments)
        let partitioned = partition([
            "CMUX_AGENT_LAUNCH_ARGV_B64": raw,
            "CMUX_AGENT_LAUNCH_KIND": "codex",
        ])

        #expect(partitioned.ephemeral["CMUX_AGENT_LAUNCH_ARGV_B64"] == raw)
        #expect(partitioned.merged["CMUX_AGENT_LAUNCH_ARGV_B64"] == raw)
        let durable = try #require(partitioned.durable["CMUX_AGENT_LAUNCH_ARGV_B64"])
        #expect(decodeArguments(durable) == [
            "/usr/local/bin/codex", "--model", "gpt-5.4",
        ])
        #expect(!durable.contains("argv-secret"))
    }

    @Test("Trusts missing launch kind only for a native hook agent capture")
    func trustsMissingLaunchKindOnlyForNativeAgent() throws {
        let nativeRaw = encodeArguments([
            "/opt/cmux/bin/codex", "--model", "gpt-5.4", "private prompt",
        ])
        let native = partition([
            "CMUX_AGENT_LAUNCH_ARGV_B64": nativeRaw,
        ])
        #expect(native.ephemeral["CMUX_AGENT_LAUNCH_ARGV_B64"] == nativeRaw)
        #expect(decodeArguments(try #require(native.durable["CMUX_AGENT_LAUNCH_ARGV_B64"])) == [
            "/opt/cmux/bin/codex", "--model", "gpt-5.4",
        ])

        let inheritedRaw = encodeArguments([
            "/opt/claude/bin/claude", "--model", "sonnet", "ancestor prompt",
        ])
        for environment in [
            ["CMUX_AGENT_LAUNCH_ARGV_B64": inheritedRaw],
            [
                "CMUX_AGENT_LAUNCH_ARGV_B64": inheritedRaw,
                "CMUX_AGENT_LAUNCH_KIND": "claude",
            ],
        ] {
            let inherited = partition(environment)
            #expect(inherited.ephemeral["CMUX_AGENT_LAUNCH_ARGV_B64"] == inheritedRaw)
            #expect(inherited.durable["CMUX_AGENT_LAUNCH_ARGV_B64"] == nil)
        }

        let malformed = "not-base64-or-safe-to-persist"
        let malformedCapture = partition([
            "CMUX_AGENT_LAUNCH_ARGV_B64": malformed,
            "CMUX_AGENT_LAUNCH_KIND": "codex",
        ])
        #expect(malformedCapture.ephemeral["CMUX_AGENT_LAUNCH_ARGV_B64"] == malformed)
        #expect(malformedCapture.durable["CMUX_AGENT_LAUNCH_ARGV_B64"] == nil)
    }

    @Test("Keeps AWS container credential URI capabilities ephemeral")
    func keepsAWSContainerCredentialURIsEphemeral() {
        let values = [
            "AWS_CONTAINER_CREDENTIALS_FULL_URI":
                "http://169.254.170.2/v2/credentials/plain-path-capability",
            "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI":
                "/v2/credentials/plain-path-capability",
        ]
        let partitioned = partition(values)

        for (key, value) in values {
            #expect(partitioned.ephemeral[key] == value)
            #expect(partitioned.durable[key] == nil)
        }
    }

    @Test("Rejects provider credential blobs, signed URLs, and malformed endpoints")
    func rejectsUnsafeProviderValues() {
        let values = [
            "GOOGLE_APPLICATION_CREDENTIALS":
                #"{"type":"service_account","private_key":"provider-blob-secret"}"#,
            "AWS_CONFIG_FILE":
                "[default]\naws_access_key_id=provider-blob-secret",
            "OPENAI_BASE_URL":
                "https://api.example.test/v1?sig=signed-url-secret",
            "ANTHROPIC_BASE_URL":
                "api.example.test/not-an-absolute-url",
            "OPENAI_EXPERIMENTAL_PROVIDER_STATE":
                "unknown-provider-value",
        ]
        let partitioned = partition(values)

        for (key, value) in values {
            #expect(partitioned.ephemeral[key] == value)
            #expect(partitioned.durable[key] == nil)
        }
    }

    @Test("Persists exact safe locators and credential-free network endpoints")
    func persistsValidatedLocatorsAndEndpoints() {
        let values = [
            "AWS_CONFIG_FILE": "/Users/example/.aws/config",
            "AWS_SHARED_CREDENTIALS_FILE": "/Users/example/.aws/credentials",
            "AWS_WEB_IDENTITY_TOKEN_FILE": "/var/run/secrets/aws/token",
            "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE": "/var/run/secrets/aws/container-token",
            "GOOGLE_APPLICATION_CREDENTIALS": "/Users/example/.config/gcloud/service-account.json",
            "AWS_PROFILE": "bedrock-profile",
            "XAI_BASE_URL": "https://api.x.ai/v1",
            "HTTPS_PROXY": "socks5h://127.0.0.1:1080",
        ]
        let partitioned = partition(values)

        for (key, value) in values {
            #expect(partitioned.durable[key] == value)
            #expect(partitioned.ephemeral[key] == nil)
        }
    }

    private func encodeArguments(_ arguments: [String]) -> String {
        var data = Data()
        for argument in arguments {
            data.append(contentsOf: argument.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

    private func decodeArguments(_ encoded: String) -> [String]? {
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return data.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
    }

    private func partition(_ environment: [String: String]) -> AgentHookTransportEnvironment {
        AgentHookTransportEnvironmentPolicy().partitionedEnvironment(
            from: environment,
            hookAgentKind: "codex"
        )
    }
}
