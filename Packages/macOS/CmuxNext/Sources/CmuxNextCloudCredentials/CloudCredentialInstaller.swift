import Foundation

/// Secret bytes travel only in writeFile's body. Exec carries a private staging path, never a
/// token. A login goes only where the caller's attach answer says they own the machine
/// (``CloudCredentialTransfer`` checks it before and after the login) and where the guest is an
/// owner machine too: on a team guest every member's terminal runs as the same Unix user and could
/// read it. The image's launchers stay authoritative; shared and old images fail closed.
nonisolated enum CloudCredentialInstaller {
    static let preflight = #"""
        set -eu
        [ "$(cat /etc/cmux/vm-kind 2>/dev/null)" = owner ]
        [ -f /etc/cmux/agent-auth.sh ]
        if [ "$(id -u)" = 0 ]; then install -d -m 700 -o cmux -g cmux /home/cmux/.cmux/credential-transfer; else
          [ "$(id -un)" = cmux ]; mkdir -p /home/cmux/.cmux/credential-transfer; chmod 700 /home/cmux/.cmux/credential-transfer
        fi
        """#

    /// The DEV and dogfood creator allowance (``CloudCredentialTransfer/allowsCreatorTeamGuest``): an
    /// owner or team guest, the caller's ownership answer being checked by the transfer itself. Every
    /// other check of ``preflight`` stays.
    static let creatorTeamPreflight = #"""
        set -eu
        case "$(cat /etc/cmux/vm-kind 2>/dev/null)" in owner|team) ;; *) exit 1 ;; esac
        [ -f /etc/cmux/agent-auth.sh ]
        if [ "$(id -u)" = 0 ]; then install -d -m 700 -o cmux -g cmux /home/cmux/.cmux/credential-transfer; else
          [ "$(id -un)" = cmux ]; mkdir -p /home/cmux/.cmux/credential-transfer; chmod 700 /home/cmux/.cmux/credential-transfer
        fi
        """#

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func command(provider: CloudCredentialTransfer.Provider, payloadPath: String, creatorTeamGuest: Bool = false) -> String {
        // Reuse the image's exact own-mode normalization: only its known endpoint/placeholder
        // values are removed. Custom endpoints remain visible to the installer's conflict guard.
        "set -e\n. /etc/cmux/agent-auth.sh\ncmux_agent_drop_model_plane_env\n"
            + "python3 - \(quote(provider.rawValue)) \(quote(payloadPath)) \(creatorTeamGuest ? "owner,team" : "owner") <<'CMUX_CREDENTIAL_INSTALL'\n" + script + "\nCMUX_CREDENTIAL_INSTALL"
    }

    /// Tests execute this installer against a scratch HOME/policy directory, then source the real
    /// image's agent-auth.sh to verify that the next launcher chooses the delivered own login.
    static let script = #"""
        import json, os, pathlib, pwd, stat, sys, tempfile
        provider, source = sys.argv[1:3]
        kinds = set((sys.argv[3] if len(sys.argv) > 3 else 'owner').split(',')) & {'owner', 'team'}
        policy = pathlib.Path('/etc/cmux')
        if (policy / 'vm-kind').read_text().strip() not in kinds or not (policy / 'agent-auth.sh').is_file():
            sys.exit(70)
        user = pwd.getpwnam('cmux')
        home = pathlib.Path(user.pw_dir)
        source = pathlib.Path(source)
        if source.is_symlink() or not source.is_file(): sys.exit(71)
        if os.geteuid() == 0:
            os.chown(source, user.pw_uid, user.pw_gid)
            os.setgroups([]); os.setgid(user.pw_gid); os.setuid(user.pw_uid)
        if os.geteuid() != user.pw_uid: sys.exit(71)
        os.umask(0o077)
        def private_dir(path):
            if path.is_symlink(): raise ValueError()
            path.mkdir(parents=True, exist_ok=True)
            if path.stat().st_uid != os.geteuid(): raise ValueError()
            path.chmod(0o700)
        def save(path, value):
            private_dir(path.parent)
            if path.is_symlink(): raise ValueError()
            fd, tmp = tempfile.mkstemp(dir=path.parent)
            try:
                os.fchmod(fd, 0o600)
                with os.fdopen(fd, 'w') as f: f.write(value)
                os.replace(tmp, path)
            finally:
                if os.path.exists(tmp): os.unlink(tmp)
        try:
            # Custom endpoints/keys must never receive the transferred subscription credential.
            conflicts = ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL',
                         'CLAUDE_CONFIG_DIR', 'OPENAI_BASE_URL', 'CODEX_HOME', 'CODEX_API_KEY']
            if any(os.environ.get(k) for k in conflicts): raise ValueError()
            if os.environ.get('CMUX_' + provider.upper() + '_AUTH') == 'team': raise ValueError()
            value = source.read_text()
            if provider == 'claude':
                settings = home / '.claude/settings.json'
                if settings.is_symlink(): raise ValueError()
                config = json.loads(settings.read_text()) if settings.exists() else {}
                env = config.setdefault('env', {})
                if 'apiKeyHelper' in config or any(env.get(k) for k in conflicts): raise ValueError()
                env['CLAUDE_CODE_OAUTH_TOKEN'] = value
                save(settings, json.dumps(config))
                # The image launcher checks this standard Claude login marker before starting
                # Claude; keep the token in the same private 0600 file so the next launch selects own.
                save(home / '.claude/.credentials.json', json.dumps({'claudeAiOauth': {'accessToken': value}}))
            elif provider == 'codex':
                config = home / '.codex/config.toml'
                if config.is_symlink(): raise ValueError()
                if config.exists():
                    import tomllib
                    settings = tomllib.loads(config.read_text())
                    if settings.get('model_provider', 'openai') not in ('openai', 'cmux'): raise ValueError()
                    if settings.get('cli_auth_credentials_store', 'file') not in ('file', 'auto'): raise ValueError()
                save(home / '.codex/auth.json', json.dumps(json.loads(value)))
            else: raise ValueError()
            save(home / '.config/cmux/agent-auth' / provider, 'own\n')
        except Exception:
            sys.exit(72)
        finally:
            source.unlink(missing_ok=True)
        """#
}
