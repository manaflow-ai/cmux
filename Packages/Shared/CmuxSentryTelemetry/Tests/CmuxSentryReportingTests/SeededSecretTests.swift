import CmuxSentryScrubbing
import Sentry
import Testing

@testable import CmuxSentryReporting

/// Puts known secrets in every field of one Sentry event, scrubs it, and checks that none of them is left
/// anywhere in the event's serialized form, the payload the SDK sends (docs/privacy.md, "Telemetry").
///
/// The field tests in ``SentryEventScrubberTests`` check one field each; this one checks the whole report at once,
/// so a field the scrubber skips, or a secret shape no rule matches, fails here by name.
@Suite struct SeededSecretTests {
    /// A seeded secret: the text placed in the event, and the part of it that must not survive.
    struct Seed: CustomStringConvertible {
        let name: String
        let text: String
        let marker: String
        var description: String { name }
    }

    /// Each token is split in two so the repository's secret scanning does not read the samples as real ones.
    static let seeds: [Seed] = [
        Seed(name: "Anthropic key", text: "sk" + "-ant-api03-SEEDanthropicKEY0123456789abcdef", marker: "SEEDanthropicKEY"),
        Seed(name: "OpenAI key", text: "sk" + "-proj-SEEDopenaiKEY0123456789abcdefgh", marker: "SEEDopenaiKEY"),
        Seed(name: "GitHub classic PAT", text: "gh" + "p_SEEDgithubPAT0123456789abcdefABCD", marker: "SEEDgithubPAT"),
        Seed(
            name: "GitHub fine-grained PAT",
            text: "gi" + "thub_pat_11SEEDGITHUBFINE0123456789_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP",
            marker: "SEEDGITHUBFINE"
        ),
        Seed(name: "GitLab PAT", text: "gl" + "pat-SEEDgitlab0123456789abcd", marker: "SEEDgitlab"),
        Seed(name: "npm token", text: "np" + "m_SEEDnpmTOKEN0123456789abcdefghijklmn", marker: "SEEDnpmTOKEN"),
        Seed(name: "Hugging Face token", text: "hf" + "_SEEDhuggingface0123456789abcdefghij", marker: "SEEDhuggingface"),
        Seed(name: "Google API key", text: "AI" + "zaSEEDgoogleKey0123456789abcdefghijklm", marker: "SEEDgoogleKey"),
        Seed(name: "Slack token", text: "xo" + "xb-SEEDslack-0123456789-abcdefABCDEF", marker: "SEEDslack"),
        Seed(name: "AWS access key id", text: "AK" + "IASEEDAWSKEY012345", marker: "SEEDAWSKEY"),
        Seed(
            name: "JWT",
            text: "ey" + "JhbGciOiJIUzI1NiJ9.eyJzdWIiOiJzZWVkIn0.SEEDjwtSignature0123456789",
            marker: "SEEDjwtSignature"
        ),
        Seed(name: "Bearer header", text: "Authorization: Bearer SEEDbearer0123456789abcdef", marker: "SEEDbearer"),
        Seed(name: "password assignment", text: "password=SEEDpasswordValue99", marker: "SEEDpasswordValue"),
        Seed(
            name: "URL credentials",
            text: "https://seeduser:SEEDurlPassword99@git.corp.dev/repo.git",
            marker: "SEEDurlPassword"
        ),
        Seed(name: "URL user name", text: "https://seeduser:SEEDurlPassword99@git.corp.dev/repo.git", marker: "seeduser"),
        Seed(
            name: "PEM private key",
            text: "-----BEGIN PRIVATE KEY-----\nSEEDpemBody0123456789\n-----END PRIVATE KEY-----",
            marker: "SEEDpemBody"
        ),
        Seed(name: "email", text: "seeded.person@corp-mail.dev", marker: "seeded.person"),
        Seed(name: "macOS user name", text: "/Users/seededalice/projects/plan.txt", marker: "seededalice"),
        Seed(name: "Linux user name", text: "/home/seededbob/.ssh/id_ed25519", marker: "seededbob"),
    ]

    /// Every seed in one free-text line, the way a log message or exception value carries it.
    static let line = seeds.map(\.text).joined(separator: " | ")

    /// One event with ``line`` in every field a report sends.
    static func seededEvent() -> Event {
        let event = Event()
        event.message = SentryMessage(formatted: line)
        event.serverName = line
        event.transaction = line
        event.logger = line

        let frame = Frame()
        frame.fileName = "/Users/seededalice/work/App.swift"
        frame.package = "/Users/seededalice/Library/Developer/cmux.app"
        frame.contextLine = line
        frame.preContext = [line]
        frame.postContext = [line]
        frame.vars = ["note": line, "token": "plain-SEEDvarToken"]
        let exception = Exception(value: line, type: "SeededError")
        exception.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
        let mechanism = Mechanism(type: "NSError")
        mechanism.desc = line
        mechanism.data = ["note": line]
        exception.mechanism = mechanism
        event.exceptions = [exception]

        let thread = SentryThread(threadId: 0)
        thread.name = line
        let threadFrame = Frame()
        threadFrame.contextLine = line
        thread.stacktrace = SentryStacktrace(frames: [threadFrame], registers: [:])
        event.threads = [thread]

        let image = DebugMeta()
        image.codeFile = "/Users/seededalice/Library/Developer/cmux.app/cmux"
        event.debugMeta = [image]

        let request = SentryRequest()
        request.url = "https://seeduser:SEEDurlPassword99@git.corp.dev/x?token=SEEDqueryToken&note=ok"
        request.queryString = "token=SEEDqueryToken&page=2"
        request.fragment = line
        request.cookies = "session=SEEDcookie0123456789"
        request.headers = ["Authorization": "Bearer SEEDbearer0123456789abcdef", "X-Note": line]
        event.request = request

        let user = User()
        user.userId = "SEEDuserId"
        user.email = "seeded.person@corp-mail.dev"
        user.username = "seededalice"
        user.name = "SEEDfullName"
        user.ipAddress = "203.0.113.77"
        user.data = ["note": line]
        event.user = user

        event.tags = ["note": line, "access_token": "plain-SEEDtagToken"]
        event.extra = ["note": line, "nested": ["deeper": [line]]]
        event.context = ["seeded": ["note": line], "credentials": ["value": "plain-SEEDcontextCredential"]]

        let breadcrumb = Breadcrumb(level: .info, category: "seeded")
        breadcrumb.message = line
        breadcrumb.data = ["note": line, "cookie": "plain-SEEDcrumbCookie"]
        event.breadcrumbs = [breadcrumb]
        return event
    }

    /// The structured-field seeds: values that match no free-text rule and are safe only because of where they are.
    static let structuredMarkers = [
        "SEEDvarToken", "SEEDqueryToken", "SEEDcookie", "SEEDuserId", "SEEDfullName", "203.0.113.77",
        "SEEDtagToken", "SEEDcontextCredential", "SEEDcrumbCookie",
    ]

    /// The scrubbed event as the SDK serializes it for sending.
    static func sentPayload() -> String {
        let scrubber = SentryEventScrubber(scrubber: SentryScrubber(homeDirectory: "/Users/seededalice"))
        return String(describing: scrubber.scrub(seededEvent()).serialize())
    }

    @Test(arguments: seeds)
    func noSeededSecretLeavesTheDevice(seed: Seed) {
        let payload = Self.sentPayload()
        #expect(!payload.contains(seed.marker), "\(seed.name) survived scrubbing: \(seed.marker)")
    }

    @Test(arguments: structuredMarkers)
    func noStructuredSecretLeavesTheDevice(marker: String) {
        #expect(!Self.sentPayload().contains(marker), "\(marker) survived scrubbing")
    }

    /// Each seed is in the event before scrubbing, so a pass means the scrubber removed it, not that it was never there.
    @Test func everySeedIsInTheUnscrubbedEvent() {
        let raw = String(describing: Self.seededEvent().serialize())
        for marker in Self.seeds.map(\.marker) + Self.structuredMarkers {
            #expect(raw.contains(marker), "\(marker) was not seeded")
        }
    }
}
