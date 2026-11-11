//! What the classic iOS app (`ios/`, the same bundle id, com.cmux.app) left on a
//! phone that updates to cmux-next-ios, and what to do with it.
//!
//! An App Store update keeps the app's Keychain items and its UserDefaults. The
//! classic app's items sit in the same default Keychain access group
//! (`<team>.<bundle id>`) the NEXT app signs with first, so NEXT can see them. It
//! uses none of them: its Stack tokens live under `<bundle id>.auth`, its device
//! ids under `dev.cmux.mobile.device`, its settings under `cmuxMobile.`, `cnx.`
//! and a few `cmux.` namespaces of its own (chat, Chief, screen sharing). Nothing
//! here is migrated: the person signs in again (a clean sign-in, never a stale
//! classic session), and the classic items are deleted once.
//!
//! The decision is this module's; Swift (`ClassicLeftovers`, CmuxMobileLive) only
//! lists what is there, deletes what the plan names and records that it ran.
//! The rules are explicit on purpose:
//!
//! - Only names the classic app is known to write are deleted (a fixed list of
//!   Keychain services, UserDefaults keys and classic-only settings namespaces,
//!   read from `ios/`). Never a whole `cmux.` sweep: NEXT keeps settings there.
//! - Names NEXT owns are never deleted, even if a classic rule would match.
//! - Anything else (unknown, malformed, a system framework's key) is left alone
//!   and only counted.
//! - A Keychain that cannot be read yet (a background launch before the first
//!   unlock) plans nothing and asks to run again on the next launch.

/// One generic-password item as the Keychain listed it. Either attribute may be
/// missing or not UTF-8 (Swift passes `None` then).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeychainLeftover {
    pub service: Option<String>,
    pub account: Option<String>,
}

/// A Keychain delete: the service, and the account when the item had one.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, uniffi::Record)]
pub struct KeychainDelete {
    pub service: String,
    pub account: Option<String>,
}

/// What to do on this launch.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ClassicCleanupPlan {
    /// Classic Keychain items to delete, sorted.
    pub keychain_deletes: Vec<KeychainDelete>,
    /// Classic UserDefaults keys to remove, sorted.
    pub defaults_deletes: Vec<String>,
    /// Items and keys left alone: NEXT's own, or not known to be classic.
    pub kept: u32,
    /// Whether to record that the cleanup ran. False only when the Keychain could
    /// not be read: the next launch tries again.
    pub mark_done: bool,
}

/// The UserDefaults key that records the cleanup ran (NEXT's own prefix, so the
/// cleanup never removes it).
pub const CLASSIC_CLEANUP_MARKER: &str = "cmuxMobile.classicLeftovers.cleaned";
/// The marker's value; a later version of these rules bumps it to run again.
pub const CLASSIC_CLEANUP_VERSION: i64 = 1;

/// The marker key, for Swift.
#[uniffi::export]
pub fn classic_cleanup_marker_key() -> String {
    CLASSIC_CLEANUP_MARKER.to_owned()
}

/// Whether this launch should run the cleanup: the marker is missing, not a
/// number, or from an older version of the rules.
#[uniffi::export]
pub fn classic_cleanup_due(marker: Option<i64>) -> bool {
    marker.is_none_or(|stored| stored < CLASSIC_CLEANUP_VERSION)
}

/// The marker value to store once a plan with `mark_done` ran.
#[uniffi::export]
pub fn classic_cleanup_version() -> i64 {
    CLASSIC_CLEANUP_VERSION
}

/// The plan for this launch. `bundle_id` is the running app's
/// (`Bundle.main.bundleIdentifier`); `keychain` is every generic-password item
/// the app can see, or `None` when the Keychain could not be read;
/// `defaults_keys` are the keys of the app's own UserDefaults domain.
#[uniffi::export]
pub fn classic_cleanup_plan(
    bundle_id: String,
    keychain: Option<Vec<KeychainLeftover>>,
    defaults_keys: Vec<String>,
) -> ClassicCleanupPlan {
    let Some(keychain) = keychain else {
        return ClassicCleanupPlan { keychain_deletes: Vec::new(), defaults_deletes: Vec::new(), kept: 0, mark_done: false };
    };
    let mut kept: u32 = 0;
    let mut keychain_deletes: Vec<KeychainDelete> = Vec::new();
    for item in keychain {
        match classic_keychain_delete(&bundle_id, &item) {
            Some(delete) => keychain_deletes.push(delete),
            None => kept = kept.saturating_add(1),
        }
    }
    keychain_deletes.sort();
    keychain_deletes.dedup();
    // One delete without an account covers every item of its service.
    let whole_services: Vec<String> =
        keychain_deletes.iter().filter(|d| d.account.is_none()).map(|d| d.service.clone()).collect();
    keychain_deletes.retain(|d| d.account.is_none() || !whole_services.contains(&d.service));

    let mut defaults_deletes: Vec<String> = Vec::new();
    for key in defaults_keys {
        if is_classic_defaults_key(&key) {
            defaults_deletes.push(key);
        } else {
            kept = kept.saturating_add(1);
        }
    }
    defaults_deletes.sort();
    defaults_deletes.dedup();
    ClassicCleanupPlan { keychain_deletes, defaults_deletes, kept, mark_done: true }
}

/// The delete for one item, or `None` to leave it.
fn classic_keychain_delete(bundle_id: &str, item: &KeychainLeftover) -> Option<KeychainDelete> {
    let account = item.account.clone().filter(|a| !a.is_empty());
    match item.service.as_deref() {
        // The Stack SDK's own store (vendor/stack-auth-swift-sdk-prerelease) sets no
        // service: only its two token accounts are classic's; never a bare
        // empty-service delete, which would match every item without a service.
        None | Some("") => {
            let account = account?;
            let stack_token = account.starts_with("stack-auth-access-") || account.starts_with("stack-auth-refresh-");
            stack_token.then(|| KeychainDelete { service: String::new(), account: Some(account) })
        }
        Some(service) => {
            if is_next_keychain_service(bundle_id, service) || !is_classic_keychain_service(bundle_id, service) {
                return None;
            }
            Some(KeychainDelete { service: service.to_owned(), account })
        }
    }
}

/// Services cmux-next-ios writes (CmuxMobileKit, CmuxAuthRuntime as NEXT builds it).
fn is_next_keychain_service(bundle_id: &str, service: &str) -> bool {
    let own = [format!("{bundle_id}.auth"), format!("{bundle_id}.phone-keys")];
    own.iter().any(|s| s == service) || service.starts_with("dev.cmux.mobile") || service.starts_with("dev.cmux.cnx.")
}

/// Services the classic app writes (ios/, Packages/iOS, Packages/Shared on main).
fn is_classic_keychain_service(bundle_id: &str, service: &str) -> bool {
    // Stack tokens (`com.cmuxterm.app.auth.<bundle id>`), device registry ids,
    // the Cloud WireGuard identity and system VPN configs, the iroh endpoint
    // identity, relay credentials and policies, the irx JSON cache.
    if service.starts_with("com.cmuxterm.") {
        return true;
    }
    // The end-to-end push key (`ai.manaflow.cmux.phone-push.<bundle id>`) and the
    // push state shared with its notification service extension.
    if service.starts_with("ai.manaflow.cmux.") {
        return true;
    }
    // The iroh v2 installation id and endpoint keys.
    if service.starts_with(&format!("{bundle_id}.cmux-iroh-")) {
        return true;
    }
    // SSH keys made in the classic terminal.
    service == "dev.cmux.ssh.keys"
}

/// Keys cmux-next-ios owns: never removed. Besides `cmuxMobile.` and `cnx.`, NEXT
/// keeps settings under `cmux.`, its own and those of the shared packages it links
/// (CmuxMobileKit/Package.swift): chat display (`cmux.chat.display.v1`), Chief
/// colors and text size (`cmux.chief.chatColors.v1`, `cmux.chief.textZoom.v1`),
/// screen sharing (`cmux.screenSharing.defaults`, `cmux.screenSharing.scope`),
/// CmuxConversation's drafts, text size and auto-translate choices
/// (`cmux.conversation.draft.*`, `cmux.conversation.textFontSize`,
/// `cmux.conversation.autoTranslate.<conversation>`) and CmuxMobileSupport's
/// keyboard dock switch. These win over every classic rule.
fn is_next_defaults_key(key: &str) -> bool {
    const NEXT_NAMESPACES: [&str; 6] =
        ["cmuxMobile.", "cnx.", "cmux.chat.", "cmux.chief.", "cmux.screenSharing.", "cmux.conversation."];
    const NEXT_KEYS: [&str; 1] = ["cmux.mobile.debug.forceRebuildKeyboardDock.v1"];
    NEXT_KEYS.contains(&key) || NEXT_NAMESPACES.iter().any(|p| key.starts_with(p))
}

/// Settings namespaces only the classic app writes (ios/, Packages/iOS and
/// Packages/Shared on main). Each is one classic subsystem that NEXT keeps no
/// settings in; several hold per-Mac, per-account or per-team keys, so they are
/// matched as a namespace. Never the whole `cmux.` prefix: NEXT keeps settings
/// there too (see `is_next_defaults_key`).
const CLASSIC_DEFAULTS_NAMESPACES: [&str; 12] = [
    // Task composer, templates, feed, terminal and debug settings, remote flags,
    // paired-Mac backup and recovery, workspace snapshots, haptics, scrollback.
    "cmux.mobile.",
    // Push opt-in, device token, registered account, pending unregisters.
    "cmux.notifications.",
    // Device registry id and its witness.
    "cmux.deviceRegistry.",
    // iroh config, path preference, identity, broker credentials, app instance.
    "cmux.iroh.",
    // Terminal toolbar, accessory bar and zoom.
    "cmux.terminal.toolbar.",
    "cmux.terminal.accessory.",
    "cmux.terminal.zoom.",
    // Debug and diagnostics switches.
    "cmux.debug.",
    "cmux.diagnostics.",
    // Cloud device identity.
    "cmux.cloud.",
    // The paired-Mac backup's legacy migration markers.
    "cmux.pairedMacBackup.",
    // Failed push replies kept for retry.
    "cmux.push.reply.failure.",
];

/// Exact classic settings keys.
const CLASSIC_DEFAULTS_KEYS: [&str; 13] = [
    // Auth.
    "auth_stack_project_id",
    "auth_has_tokens",
    "auth_cached_user",
    "auth_selected_team",
    "AuthEnvironment",
    "selected_team",
    "has_tokens",
    "cached_user",
    // Presence and telemetry.
    "presenceServiceURL",
    "sendAnonymousTelemetry",
    // Mac selection, simulator stream quality, the Keychain migration marker.
    "cmux.workspaces.macSelection",
    "cmux.simulatorStream.quality",
    "cmux.v2.keychain.migration-complete",
];

/// UserDefaults keys the classic app writes: a named classic key, or a key in a
/// named classic namespace; never one of NEXT's.
fn is_classic_defaults_key(key: &str) -> bool {
    if is_next_defaults_key(key) {
        return false;
    }
    CLASSIC_DEFAULTS_KEYS.contains(&key) || CLASSIC_DEFAULTS_NAMESPACES.iter().any(|p| key.starts_with(p))
}

#[cfg(test)]
mod tests {
    use super::*;

    const B: &str = "com.cmux.app";

    fn item(service: Option<&str>, account: Option<&str>) -> KeychainLeftover {
        KeychainLeftover { service: service.map(str::to_owned), account: account.map(str::to_owned) }
    }

    fn delete(service: &str, account: Option<&str>) -> KeychainDelete {
        KeychainDelete { service: service.to_owned(), account: account.map(str::to_owned) }
    }

    /// Every item the classic App Store build writes, as `ios/` names them.
    fn classic_keychain() -> Vec<KeychainLeftover> {
        vec![
            item(Some("com.cmuxterm.app.auth.com.cmux.app"), Some("cmux-auth-access-token")),
            item(Some("com.cmuxterm.app.auth.com.cmux.app"), Some("cmux-auth-refresh-token")),
            item(Some("ai.manaflow.cmux.phone-push.com.cmux.app"), Some("v1")),
            item(Some("ai.manaflow.cmux.phone-push.shared-state"), Some("cmux.activeAccountID.com.cmux.app")),
            item(Some("ai.manaflow.cmux.phone-push.shared-state"), Some("cmux.phone-push.peer.v2.registry")),
            item(Some("com.cmux.app.cmux-iroh-v2.installation"), Some("device-id")),
            item(Some("com.cmux.app.cmux-iroh-v2.endpoint-keys"), Some("0f".repeat(32).as_str())),
            item(Some("com.cmuxterm.deviceRegistry.iosDeviceID.v1.com.cmux.app"), Some("default")),
            item(Some("com.cmuxterm.deviceRegistry.iosDeviceID.v1"), Some("default")),
            item(Some("com.cmuxterm.iroh.endpoint-identity.v1"), Some("identity")),
            item(Some("com.cmuxterm.cloud.wireguard.v1.com.cmux.app"), Some("cloud-device-identity")),
            item(Some("com.cmuxterm.cloud.system-vpn.v1.com.cmux.app"), Some("cloud-system-vpn-6F1C")),
            item(Some("com.cmuxterm.irx.cache.v1"), Some("teams|user-1|api.cmux.dev")),
            item(Some("com.cmuxterm.iroh.relay-credentials.v1"), Some("relay")),
            item(Some("dev.cmux.ssh.keys"), Some("8C1F")),
            item(None, Some("stack-auth-access-9790718f")),
            item(Some(""), Some("stack-auth-refresh-9790718f")),
        ]
    }

    /// What NEXT itself writes under the same bundle id.
    fn next_keychain() -> Vec<KeychainLeftover> {
        vec![
            item(Some("com.cmux.app.auth"), Some("cmux-auth-access-token")),
            item(Some("com.cmux.app.auth"), Some("cmux-auth-refresh-token")),
            item(Some("com.cmux.app.phone-keys"), Some("keys")),
            item(Some("dev.cmux.mobile.device"), Some("link.user-1")),
            item(Some("dev.cmux.mobile.push"), Some("preference.mutedChats")),
            item(Some("dev.cmux.mobile.push.handover"), Some("reply")),
            item(Some("dev.cmux.mobile.openai-api-key"), Some("key")),
            item(Some("dev.cmux.cnx.device"), Some("presence.user-1")),
        ]
    }

    fn classic_defaults() -> Vec<String> {
        [
            "auth_stack_project_id",
            "auth_has_tokens",
            "auth_cached_user",
            "AuthEnvironment",
            "cmux.iroh.v2.config.CMUX_IROH_V2_ENVIRONMENT",
            "cmux.iroh.pathPreference",
            "cmux.deviceRegistry.iosDeviceID",
            "cmux.notifications.deviceTokenHex",
            "cmux.mobile.flags.remote.chat",
            "presenceServiceURL",
            "sendAnonymousTelemetry",
        ]
        .map(str::to_owned)
        .to_vec()
    }

    #[test]
    fn an_update_from_classic_deletes_every_classic_item_and_keeps_next() {
        let mut keychain = classic_keychain();
        keychain.extend(next_keychain());
        let mut defaults = classic_defaults();
        defaults.extend(["cmuxMobile.setupComplete", "cnx.lastTeamID", "AppleLanguages", "WebKitShowsURLsInToolTips"].map(str::to_owned));

        let plan = classic_cleanup_plan(B.to_owned(), Some(keychain), defaults);

        let deleted: Vec<&str> = plan.keychain_deletes.iter().map(|d| d.service.as_str()).collect();
        assert_eq!(plan.keychain_deletes.len(), classic_keychain().len());
        for next in next_keychain() {
            assert!(!deleted.contains(&next.service.as_deref().unwrap_or_default()), "deleted NEXT's {next:?}");
        }
        assert!(plan.keychain_deletes.contains(&delete("com.cmuxterm.app.auth.com.cmux.app", Some("cmux-auth-access-token"))));
        assert!(plan.keychain_deletes.contains(&delete("", Some("stack-auth-access-9790718f"))));
        let mut want = classic_defaults();
        want.sort();
        assert_eq!(plan.defaults_deletes, want);
        // NEXT's 8 items, NEXT's 2 keys and 2 system keys.
        assert_eq!(plan.kept, 12);
        assert!(plan.mark_done);
    }

    #[test]
    fn malformed_and_unknown_items_are_left_alone() {
        let keychain = vec![
            item(None, None),
            item(Some(""), None),
            item(Some(""), Some("")),
            item(None, Some("someone-elses-account")),
            item(Some("com.example.sdk"), Some("token")),
            item(Some("com.cmux.app"), Some("x")),
        ];
        let plan = classic_cleanup_plan(B.to_owned(), Some(keychain), vec![String::new(), "unknown".to_owned()]);
        assert!(plan.keychain_deletes.is_empty());
        assert!(plan.defaults_deletes.is_empty());
        assert_eq!(plan.kept, 8);
        assert!(plan.mark_done);
    }

    #[test]
    fn a_classic_item_without_an_account_deletes_its_whole_service_once() {
        let keychain = vec![
            item(Some("dev.cmux.ssh.keys"), None),
            item(Some("dev.cmux.ssh.keys"), Some("8C1F")),
            item(Some("dev.cmux.ssh.keys"), Some("")),
        ];
        let plan = classic_cleanup_plan(B.to_owned(), Some(keychain), Vec::new());
        assert_eq!(plan.keychain_deletes, vec![delete("dev.cmux.ssh.keys", None)]);
    }

    #[test]
    fn an_unreadable_keychain_plans_nothing_and_runs_again() {
        let plan = classic_cleanup_plan(B.to_owned(), None, classic_defaults());
        assert!(plan.keychain_deletes.is_empty());
        assert!(plan.defaults_deletes.is_empty());
        assert!(!plan.mark_done);
    }

    #[test]
    fn a_second_launch_finds_nothing_to_delete() {
        let plan = classic_cleanup_plan(B.to_owned(), Some(next_keychain()), vec!["cmuxMobile.setupComplete".to_owned()]);
        assert!(plan.keychain_deletes.is_empty());
        assert!(plan.defaults_deletes.is_empty());
    }

    #[test]
    fn the_rules_follow_the_bundle_id() {
        // A classic INTERNAL install updated to NEXT INTERNAL: the same rules,
        // NEXT's own services named by its bundle id.
        let internal = "dev.cmux.app.internal";
        let keychain = vec![
            item(Some("com.cmuxterm.app.auth.dev.cmux.app.internal"), Some("cmux-auth-access-token")),
            item(Some("dev.cmux.app.internal.cmux-iroh-v2.installation"), Some("device-id")),
            item(Some("dev.cmux.app.internal.auth"), Some("cmux-auth-access-token")),
            item(Some("dev.cmux.app.internal.phone-keys"), Some("keys")),
            // Another bundle's iroh items are not this app's classic ones.
            item(Some("com.cmux.app.cmux-iroh-v2.installation"), Some("device-id")),
        ];
        let plan = classic_cleanup_plan(internal.to_owned(), Some(keychain), Vec::new());
        assert_eq!(
            plan.keychain_deletes,
            vec![
                delete("com.cmuxterm.app.auth.dev.cmux.app.internal", Some("cmux-auth-access-token")),
                delete("dev.cmux.app.internal.cmux-iroh-v2.installation", Some("device-id")),
            ]
        );
        assert_eq!(plan.kept, 3);
    }

    /// The `cmux.` settings NEXT writes today: its own (ChatPolishActions,
    /// ChiefChatColors, ChiefTextZoom, ScreenSharingPreferences) and those of the
    /// shared packages it links (CmuxConversation, CmuxMobileSupport).
    const NEXT_CMUX_DEFAULTS: [&str; 9] = [
        "cmux.chat.display.v1",
        "cmux.chief.chatColors.v1",
        "cmux.chief.textZoom.v1",
        "cmux.screenSharing.defaults",
        "cmux.screenSharing.scope",
        "cmux.conversation.autoTranslate.c39c6f72",
        "cmux.conversation.draft.chief.c39c6f72",
        "cmux.conversation.textFontSize",
        "cmux.mobile.debug.forceRebuildKeyboardDock.v1",
    ];

    #[test]
    fn next_settings_under_cmux_survive_the_cleanup() {
        let mut defaults: Vec<String> = NEXT_CMUX_DEFAULTS.map(str::to_owned).to_vec();
        // A `cmux.` key neither app is known to write is left alone too.
        defaults.push("cmux.someFutureSetting".to_owned());
        defaults.extend(classic_defaults());

        let plan = classic_cleanup_plan(B.to_owned(), Some(Vec::new()), defaults);

        for key in NEXT_CMUX_DEFAULTS {
            assert!(!plan.defaults_deletes.iter().any(|d| d == key), "deleted NEXT's {key}");
            assert!(!is_classic_defaults_key(key), "{key} matches a classic rule");
        }
        assert!(!plan.defaults_deletes.iter().any(|d| d == "cmux.someFutureSetting"));
        let mut want = classic_defaults();
        want.sort();
        assert_eq!(plan.defaults_deletes, want);
        assert_eq!(plan.kept, 10);
    }

    #[test]
    fn classic_rules_are_named_keys_and_namespaces_never_all_of_cmux() {
        for namespace in CLASSIC_DEFAULTS_NAMESPACES {
            assert!(namespace.starts_with("cmux.") && namespace.len() > "cmux.".len() + 1, "{namespace}");
            assert!(namespace.ends_with('.'), "{namespace} must be a namespace");
            assert!(!is_next_defaults_key(namespace), "{namespace} overlaps NEXT");
        }
        for key in ["cmux.", "cmux.x", "auth_token", "auth_somethingNew"] {
            assert!(!is_classic_defaults_key(key), "{key}");
        }
    }

    #[test]
    fn next_keys_are_never_classic_even_with_a_classic_looking_tail() {
        assert!(!is_classic_defaults_key("cmuxMobile.auth_has_tokens"));
        assert!(!is_classic_defaults_key("cnx.cmux.iroh"));
        assert!(is_classic_defaults_key("cmux.notifications.pushEnabled"));
        assert!(!is_classic_defaults_key("cmux.chief.mobile.x"));
    }

    #[test]
    fn the_marker_runs_once_per_version() {
        assert!(classic_cleanup_due(None));
        assert!(classic_cleanup_due(Some(0)));
        assert!(!classic_cleanup_due(Some(CLASSIC_CLEANUP_VERSION)));
        assert!(!classic_cleanup_due(Some(CLASSIC_CLEANUP_VERSION + 1)));
        assert!(is_next_defaults_key(&classic_cleanup_marker_key()));
    }
}
