#if DEBUG
import Foundation

/// DEBUG ONLY (Environment Secrets Playground): the sample environment every direction draws. Made-up
/// names and `EXAMPLE` values only; no real secret is in this file.
struct EnvSecretsSample {
    let environment = "storefront-web"
    let team = "Northwind"

    /// The `.env` text the paste state starts from.
    let pasted = """
    NODE_ENV=production
    REGION=us-east-1
    STRIPE_SECRET_KEY=sk_test_EXAMPLE00000000000000Q7rT
    DATADOG_API_KEY=dd_EXAMPLE000000000000000c41e
    MAPS_API_KEY=maps_EXAMPLE0000000000000Lk2w
    NPM_TOKEN=npm_EXAMPLE00000000000000aB12
    LEGACY_LICENSE=lic-EXAMPLE-0000-9f3c
    """

    /// The rows the paste turns into, each with the type picked from its name and value.
    let review: [EnvSecretsEntry] = [
        EnvSecretsEntry(name: "NODE_ENV", kind: .variable, value: "production", reason: "Common setting name, plain word value"),
        EnvSecretsEntry(name: "REGION", kind: .variable, value: "us-east-1", reason: "Plain word value"),
        EnvSecretsEntry(name: "STRIPE_SECRET_KEY", kind: .apiSecret, last4: "Q7rT", hosts: ["api.stripe.com"], delivery: .bearer,
                        reason: "Known name: host filled in"),
        EnvSecretsEntry(name: "DATADOG_API_KEY", kind: .apiSecret, last4: "c41e", hosts: ["api.datadoghq.com"], delivery: .header("DD-API-KEY"),
                        reason: "Known name: host and header filled in"),
        EnvSecretsEntry(name: "MAPS_API_KEY", kind: .apiSecret, last4: "Lk2w", hosts: ["maps.googleapis.com"], delivery: .query("key"),
                        reason: "Known name: sent as a query value"),
        EnvSecretsEntry(name: "NPM_TOKEN", kind: .setupSecret, last4: "aB12", reason: "Used by package installs in the setup script"),
        EnvSecretsEntry(name: "LEGACY_LICENSE", kind: .envSecret, last4: "9f3c",
                        reason: "License keys are read by local tools, not sent to an API"),
    ]

    /// The saved environment.
    let saved: [EnvSecretsEntry] = [
        EnvSecretsEntry(name: "STRIPE_SECRET_KEY", kind: .apiSecret, last4: "Q7rT", hosts: ["api.stripe.com"], delivery: .bearer,
                        setBy: "Mia Chen", setAt: "Nov 18, 2:14 PM", version: 3),
        EnvSecretsEntry(name: "DATADOG_API_KEY", kind: .apiSecret, last4: "c41e", hosts: ["api.datadoghq.com", "http-intake.logs.datadoghq.com"],
                        delivery: .header("DD-API-KEY"), setBy: "Jordan Lee", setAt: "Nov 12, 9:03 AM"),
        EnvSecretsEntry(name: "NPM_TOKEN", kind: .setupSecret, last4: "aB12", setBy: "Mia Chen", setAt: "Oct 30, 4:41 PM", version: 2),
        EnvSecretsEntry(name: "LEGACY_LICENSE", kind: .envSecret, last4: "9f3c", setBy: "Priya Natarajan", setAt: "Oct 2, 11:20 AM"),
        EnvSecretsEntry(name: "NODE_ENV", kind: .variable, value: "production", setBy: "Jordan Lee", setAt: "Sep 21, 10:00 AM"),
        EnvSecretsEntry(name: "REGION", kind: .variable, value: "us-east-1", setBy: "Jordan Lee", setAt: "Sep 21, 10:00 AM"),
    ]

    /// A secret that has no host yet.
    let noHost = EnvSecretsEntry(name: "INTERNAL_SIGNING_KEY", kind: .apiSecret, last4: "u8Pz", delivery: .bearer,
                                 reason: "Looks like a key, but its name matches no known service")

    /// The pending host change on a team secret.
    let pendingHost = "hooks.stripe.com"
    let pendingBy = "Jordan Lee"
    let pendingAt = "Today, 3:52 PM"
    let approver = "Mia Chen"

    /// The audit history of `STRIPE_SECRET_KEY`.
    let audit: [EnvSecretsAuditEvent] = [
        EnvSecretsAuditEvent(id: 0, time: "Today, 4:07 PM", outcome: .sent, who: "Fix checkout tax rounding", host: "api.stripe.com", detail: "200"),
        EnvSecretsAuditEvent(id: 1, time: "Today, 4:06 PM", outcome: .blocked, who: "Fix checkout tax rounding", host: "paste.example.net",
                             detail: "Host not allowed"),
        EnvSecretsAuditEvent(id: 2, time: "Today, 3:58 PM", outcome: .sent, who: "Refund webhook tests", host: "api.stripe.com", detail: "200"),
        EnvSecretsAuditEvent(id: 3, time: "Today, 3:52 PM", outcome: .hostAdded, who: "Jordan Lee", host: "hooks.stripe.com",
                             detail: "Waiting for an admin"),
        EnvSecretsAuditEvent(id: 4, time: "Nov 18, 2:14 PM", outcome: .replaced, who: "Mia Chen", host: "—", detail: "Version 3"),
        EnvSecretsAuditEvent(id: 5, time: "Nov 2, 9:30 AM", outcome: .replaced, who: "Mia Chen", host: "—", detail: "Version 2"),
        EnvSecretsAuditEvent(id: 6, time: "Oct 14, 1:12 PM", outcome: .created, who: "Mia Chen", host: "api.stripe.com", detail: "Version 1"),
    ]

    /// The running chats that use `STRIPE_SECRET_KEY` now.
    let runningChats = ["Fix checkout tax rounding", "Refund webhook tests", "Nightly price sync"]

    /// The agent's request for a secret it lacks (the MCP `secrets_request` card).
    let requestName = "STRIPE_RESTRICTED_KEY"
    let requestHost = "api.stripe.com"
    let requestChat = "Refund webhook tests"
    let requestReason = "Create test refunds in the Stripe test account to check the refund webhook."

    /// One name per scope, with the value each scope gives; the most specific wins.
    struct Layer: Identifiable {
        var name: String
        var kind: EnvSecretsKind
        /// The value each scope sets, nil where it sets none.
        var team: String?
        var personal: String?
        var chat: String?

        var id: String { name }

        var winner: EnvSecretsEntry.Scope {
            if chat != nil { return .chat }
            if personal != nil { return .personal }
            return .team
        }

        func value(_ scope: EnvSecretsEntry.Scope) -> String? {
            switch scope {
            case .team: team
            case .personal: personal
            case .chat: chat
            }
        }
    }

    let layers: [Layer] = [
        Layer(name: "REGION", kind: .variable, team: "us-east-1", chat: "eu-west-1"),
        Layer(name: "STRIPE_SECRET_KEY", kind: .apiSecret, team: "•••• Q7rT", personal: "•••• m3Dx"),
        Layer(name: "DATADOG_API_KEY", kind: .apiSecret, team: "•••• c41e"),
        Layer(name: "LOG_LEVEL", kind: .variable, team: "info", personal: "debug", chat: "trace"),
        Layer(name: "NPM_TOKEN", kind: .setupSecret, team: "•••• aB12"),
        Layer(name: "NODE_ENV", kind: .variable, team: "production"),
    ]
}
#endif
