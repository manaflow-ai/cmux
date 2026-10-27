import CmuxNextActions
import CmuxNextCompat
import Foundation

/// A consented, nonsecret checklist. Building it never reads the environment, Keychain,
/// credential files, or a provider CLI, and never writes to or executes on the machine.
/// The secret store/applier own any future automatic delivery; this plan cannot deliver secrets.
nonisolated struct CloudCredentialPlan {
    let machineID: String

    init(machineID: String, confirmed: Bool) throws {
        guard confirmed else {
            throw ActionFailure(message: String(localized: "cloud.credentials.confirm",
                defaultValue: "Pass --confirm to view credential setup steps for this machine. No credentials are transferred.",
                table: "CredentialPlan", bundle: .module))
        }
        self.machineID = machineID
    }

    var fields: [String: ActionResultValue] {
        [
            "machine_id": .string(machineID),
            "status": .string("plan_only"),
            "credentials_transferred": .bool(false),
            "automatic_transfer_available": .bool(false),
            "transfers": .array([]),
            "claude": .object([
                "status": .string("manual_setup_required"),
                "local_command": .string("claude setup-token"),
                "local_command_location": .string("current_machine_terminal"),
                "credential_kind": .string("new_claude_oauth_token"),
                "destination_environment_variable": .string("CLAUDE_CODE_OAUTH_TOKEN"),
                "delivery": .string("user_supplies_new_token_on_target_machine"),
                "automatic_delivery_status": .string("secret_store_dependency_unavailable"),
                "alternative_target_command": .string("claude auth login"),
                "documentation_url": .string("https://code.claude.com/docs/en/cli-reference"),
            ]),
            "codex": .object([
                "status": .string("target_login_required"),
                "target_command": .string("codex login --device-auth"),
                "target_command_location": .string("target_machine_terminal"),
                "credential_kind": .string("new_target_login"),
                "delivery": .string("provider_device_login"),
                "verification_command": .string("codex login status"),
                "device_login_requirement": .string("enabled_in_account_or_workspace"),
                "documentation_url": .string("https://developers.openai.com/codex/auth"),
            ]),
            "retained_on_current_machine": .array([
                .string("existing_claude_login"), .string("codex_auth_cache"),
                .string("keychain_entries"), .string("api_keys"), .string("ssh_keys"),
                .string("github_credentials"), .string("provider_refresh_tokens"),
            ]),
        ]
    }
}
