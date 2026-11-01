public import CmuxNextCloud
import CryptoKit
public import Foundation

/// The Claude login a Cloud machine already holds, as a `cloud.startChat` start reads it before it
/// passes the account's own (the `claude setup-token` login cmux caches, ``CloudCredentialTransfer``).
/// "A login file exists" is not enough: a machine reused from an earlier run can hold a token the
/// provider has since expired or revoked, and every turn there then fails with "The provider rejected
/// Claude Code's credentials on this Cloud machine" while cmux holds a fresh login for the account.
/// So the probe asks the provider once whether the machine's token still works, and a start replaces
/// a rejected one (``needsLogin``) just as it gives a machine with none its first.
///
/// Conservative by design: only a 401 for a token other than cmux's own cached one counts as rejected.
/// A `/login` session (Claude refreshes it itself), the cached token already there, a provider that
/// cannot be reached and any other answer leave the machine's login alone, so a start never loops on a
/// login it just installed; a later rejection is the turn card's recovery (#26148).
public nonisolated enum CloudMachineLogin: String, Sendable, Equatable, CaseIterable {
    /// No own Claude sign-in on the machine (the image's `cmux_agent_has_own_login` says so).
    case none
    /// A `/login` session with a refresh token: Claude renews it itself, so it is never replaced.
    case session
    /// The token is the one cmux holds for this account: there is nothing newer to give it.
    case cached
    /// Another token the provider did not reject, or could not be asked about.
    case working
    /// Another token the provider answered 401 for: expired or revoked.
    case rejected

    /// Whether a start gives the machine the account's login, replacing a rejected one.
    public var needsLogin: Bool { self == .none || self == .rejected }

    /// The provider endpoint the probe asks: an authenticated read that costs no tokens.
    static let endpoint = "https://api.anthropic.com/v1/models?limit=1"

    /// Reads the machine's login (with `api` already pinned to the machine's team) and whether cmux holds
    /// this account's login. Never throws: an exec that fails reads as `.none`, as the probe before it did.
    public static func read(on api: CloudAPIClient, machineID: String, teamID: String?, userID: String) async -> (login: CloudMachineLogin, cached: Bool) {
        let cached = (try? await CloudCredentialLogin.load(provider: .claude, teamID: teamID, userID: userID)) ?? nil
        guard let result = try? await api.exec(machineID, command: probe(cachedFingerprint: cached.map(fingerprint)), timeoutMs: 30_000) else {
            return (.none, cached != nil)
        }
        return (parse(exitCode: result.exitCode, stdout: result.stdout), cached != nil)
    }

    /// The SHA-256 of a token, hex: what the probe compares on the machine, so no token is sent there to compare.
    static func fingerprint(_ token: Data) -> String {
        SHA256.hash(data: token).map { String(format: "%02x", $0) }.joined()
    }

    /// The probe's one word. An unknown answer keeps today's reading of the exit code: 0 a login that stays.
    static func parse(exitCode: Int, stdout: String) -> CloudMachineLogin {
        Self(rawValue: stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? (exitCode == 0 ? .working : .none)
    }

    /// Prints one word of ``CloudMachineLogin``. The image's own detection first, with its config sourced as
    /// the launcher does; then the token Claude would use, read as the work user's (`cmux`): the
    /// `CLAUDE_CODE_OAUTH_TOKEN` of the environment or `~/.claude/settings.json`, else the access token
    /// of `~/.claude/.credentials.json`. The token goes only to the provider, in a header; the output is
    /// the word, never a token or the provider's reply.
    static func probe(cachedFingerprint: String?, endpoint: String = endpoint) -> String {
        ". /etc/cmux/agent-config.sh >/dev/null 2>&1; . /etc/cmux/agent-auth.sh && cmux_agent_has_own_login claude || { echo none; exit 0; }\n"
            + "python3 - \(CloudCredentialInstaller.quote(cachedFingerprint ?? "")) \(CloudCredentialInstaller.quote(endpoint)) <<'CMUX_LOGIN_PROBE'\n"
            + script + "\nCMUX_LOGIN_PROBE"
    }

    static let script = #"""
        import hashlib, json, os, pathlib, pwd, sys, urllib.error, urllib.request
        expected, url = sys.argv[1:3]
        def answer(word):
            print(word)
            sys.exit(0)
        try: home = pathlib.Path(pwd.getpwnam('cmux').pw_dir)
        except KeyError: home = pathlib.Path(os.environ.get('HOME') or '/root')
        def read(path):
            try: value = json.loads(path.read_text())
            except Exception: return {}
            return value if isinstance(value, dict) else {}
        def text(value): return value if isinstance(value, str) else ''
        env = read(home / '.claude/settings.json').get('env')
        token = text(os.environ.get('CLAUDE_CODE_OAUTH_TOKEN')) or text(env.get('CLAUDE_CODE_OAUTH_TOKEN') if isinstance(env, dict) else None)
        if not token:
            oauth = read(home / '.claude/.credentials.json').get('claudeAiOauth')
            if not isinstance(oauth, dict): answer('working')
            if oauth.get('refreshToken'): answer('session')
            token = text(oauth.get('accessToken'))
        if not token: answer('working')
        if expected and hashlib.sha256(token.encode()).hexdigest() == expected: answer('cached')
        request = urllib.request.Request(url, headers={'authorization': 'Bearer ' + token, 'anthropic-version': '2023-06-01',
                                                       'anthropic-beta': 'oauth-2025-04-20'})
        try:
            urllib.request.urlopen(request, timeout=8).close()
        except urllib.error.HTTPError as error:
            body = ''
            try: body = error.read(4096).decode('utf-8', 'replace')
            except Exception: pass
            # A 401 the provider gives a header it no longer takes is not this token's rejection.
            answer('rejected' if error.code == 401 and 'not supported' not in body else 'working')
        except Exception:
            answer('working')
        answer('working')
        """#
}
