public import Foundation

/// `.cmux/machine.toml`: one declared source per machine for its env, its secret names and its
/// setup (supersedes #7560's `cmux vm env` layers). `cmux cloud new-machine --machine-config FILE`
/// and `cmux cloud apply-machine-config --target machine:<id> [--machine-config FILE]` upload the
/// file (names and plain values only, never a secret value) with the applier, and one short exec
/// starts the applier detached, as the bootstrap does. Without a file, the applier takes the
/// `--repo` checkout's `.cmux/machine.toml`, else the file uploaded last time.
///
/// ```toml
/// version = 1
/// [env]                              # to ~/.config/cmux/machine.env (0600), sourced by shells
/// NODE_ENV = "development"
/// [secrets]
/// names = ["DATABASE_URL"]           # names only; reported missing until delivered
/// [setup]
/// run = ["bun install"]              # in order, bash -l, in the checkout; reruns only on change
/// timeout_minutes = 30               # per command
/// check = ["bun run typecheck"]      # reported, never a gate
/// ```
///
/// Secret values (``CloudMachineSecrets``, delivered over the daemon link) reach shells and agents
/// but never `[setup]` or `check` (run with `CMUX_MACHINE_SETUP=1`, in an environment of their own),
/// whose output goes to ``logPath`` with every delivered value masked, and never into ``statusPath``,
/// which the app reads through the Cloud file API. Masking catches a value printed by accident;
/// setup is the person's own code, run as the machine's user, which can read the values anyway.
///
/// The applier waits for a running bootstrap (the `--repo` clone) first, takes its own lock (a
/// second start says `running`), writes ``statusPath`` (`waiting|running|done|failed`, the source,
/// `config_sha`, env names, `secrets.missing`, `setup` with `failing_index`, `checks`) and ends when the last command does.
public struct CloudMachineConfig: Equatable, Sendable {
    /// The file to upload; nil applies what the machine has.
    public var contents: Data?

    public init(contents: Data?) {
        self.contents = contents
    }

    public static let directory = "/home/cmux/.cmux/machine-config"
    public static let statusPath = directory + "/status.json"
    public static let logPath = directory + "/setup.log"
    /// The transient unit the applier runs in (`systemctl status cmux-machine-config`).
    public static let unit = "cmux-machine-config"
    /// The largest file the applier takes.
    public static let maxBytes = 64 * 1024

    /// The applier (`~/.cmux/machine-config/apply`, run with `python3 -I`).
    public static let applier = #"""
        #!/usr/bin/env python3
        # cmux machine config (written by the cmux app: cmux cloud new-machine --machine-config,
        # cmux cloud apply-machine-config). Applies ~/.cmux/machine-config's machine.toml, or the
        # --repo checkout's .cmux/machine.toml: [env] to ~/.config/cmux/machine.env (0600, sourced by
        # login and interactive shells), [secrets] names reported missing until delivered, [setup] run
        # in order when it changed, [setup] check reported. Writes ./status.json; ends when done.
        import fcntl, hashlib, json, os, pwd, re, secrets, signal, stat, subprocess, sys, time, tomllib

        HOME = os.path.expanduser("~")
        D = os.path.dirname(os.path.abspath(__file__))
        BOOT = os.path.join(HOME, ".cmux/bootstrap")
        CONF = os.path.join(HOME, ".config", "cmux")
        ENV_FILE = os.path.join(CONF, "machine.env")
        SECRETS_FILE = os.path.join(CONF, "machine-secrets.env")
        HOOK = 'if [ -f "$HOME/.config/cmux/machine.env" ] && [ ! -L "$HOME/.config/cmux/machine.env" ]; then . "$HOME/.config/cmux/machine.env"; fi # cmux-machine-env'
        NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]{0,127}\Z")
        # Names the shell owns or evaluates (bash expands arithmetic variables such as OPTIND, and prompts,
        # when it reads them: `OPTIND='a[$(cmd)]'` runs cmd even single-quoted), and names cmux owns.
        RESERVED = {"PATH", "HOME", "USER", "LOGNAME", "SHELL", "IFS", "ENV", "BASH_ENV", "PROMPT_COMMAND", "PWD", "OLDPWD", "TERM",
                    "BASH", "BASHOPTS", "BASHPID", "CDPATH", "COLUMNS", "DIRSTACK", "EPOCHREALTIME", "EPOCHSECONDS", "EUID", "EXECIGNORE",
                    "FCEDIT", "FIGNORE", "FUNCNAME", "FUNCNEST", "GLOBIGNORE", "GROUPS", "HOSTFILE", "HOSTNAME", "HOSTTYPE", "IGNOREEOF",
                    "INPUTRC", "LINENO", "LINES", "MACHTYPE", "MAIL", "MAILCHECK", "MAILPATH", "OPTARG", "OPTERR", "OPTIND", "OSTYPE",
                    "PIPESTATUS", "POSIXLY_CORRECT", "PPID", "RANDOM", "REPLY", "SECONDS", "SHELLOPTS", "SHLVL", "SRANDOM", "TIMEFORMAT",
                    "TMOUT", "TMPDIR", "UID", "_", "PS0", "PS1", "PS2", "PS3", "PS4", "HISTCMD", "HISTCONTROL", "HISTFILE", "HISTFILESIZE",
                    "HISTIGNORE", "HISTSIZE", "HISTTIMEFORMAT",
                    # Locale and time zone: bash and libc echo a bad value back in their warnings.
                    "LANG", "LANGUAGE", "TZ", "TZDIR", "NLSPATH",
                    # zsh's startup and evaluated names (~/.zshenv sources this file in every zsh).
                    "ZDOTDIR", "FPATH", "MODULE_PATH", "PROMPT", "PROMPT2", "PROMPT3", "PROMPT4", "RPROMPT", "RPROMPT2", "RPS1",
                    "RPS2", "NULLCMD", "READNULLCMD", "HISTCHARS", "WATCHFMT", "PERIOD", "KEYTIMEOUT", "SAVEHIST", "STTY",
                    # Read by python3 (the applier itself, and any setup step), so a config never steers it.
                    "PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP", "PYTHONINSPECT", "PYTHONUSERBASE", "PYTHONSAFEPATH",
                    # The model plane's (~/.config/cmux/model-plane.env): a file from a repo must not route agents elsewhere.
                    "OPENAI_API_KEY", "OPENAI_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN"}
        MAX_BYTES, MAX_NAMES, MAX_COMMANDS = 64 * 1024, 100, 50
        BOOTSTRAP_WAIT_S = 3 * 3600
        STARTING_S = 60


        class Refused(Exception):
            pass


        def write(path, text, mode=0o600):
            """`text` to `path` by a new, unguessable temporary file renamed over it: never through a link."""
            tmp = f"{path}.cmux-{secrets.token_hex(8)}"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
            try:
                with os.fdopen(fd, "w") as f:
                    os.fchmod(f.fileno(), mode)
                    f.write(text)
                os.replace(tmp, path)
            except BaseException:
                if os.path.lexists(tmp):
                    os.unlink(tmp)
                raise


        def read_owned(path, limit=1 << 20):
            """`path`'s bytes: a regular file of this user, opened without following a link or blocking on a FIFO,
            and never more than `limit` bytes (None when it is larger); OSError when it is missing or not one."""
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as f:
                st = os.fstat(f.fileno())
                if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
                    raise OSError(f"{path} is not a regular file of this user")
                data = f.read(limit + 1)
            return None if len(data) > limit else data


        def status(state, **fields):
            write(os.path.join(D, "status.json"), json.dumps({"state": state, "at": int(time.time()), **fields}, sort_keys=True) + "\n")


        def quoted(value):
            return "'" + value.replace("'", "'\\''") + "'"


        def check_name(name, what):
            if not isinstance(name, str) or not NAME.match(name):
                raise Refused(f"{what} name {name!r} must match [A-Za-z_][A-Za-z0-9_]*")
            upper = name.upper()
            if upper in RESERVED or upper.startswith(("LD_", "DYLD_", "CMUX_", "BASH_", "COMP_", "PROMPT_", "READLINE_", "COPROC", "LC_", "ZSH_")):
                raise Refused(f"{what} name {name} is reserved")


        def commands(table, key):
            value = table.get(key, [])
            if not isinstance(value, list) or not all(isinstance(c, str) and c.strip() for c in value) or len(value) > MAX_COMMANDS:
                raise Refused(f"setup.{key} must be a list of at most {MAX_COMMANDS} non-empty strings")
            return value


        def parse(text):
            """The file's declarations, normalized; Refused on anything else."""
            try:
                doc = tomllib.loads(text)
            except tomllib.TOMLDecodeError as e:
                raise Refused(f"not TOML: {e}") from None
            if type(doc.get("version")) is not int or doc["version"] != 1:
                raise Refused("version must be 1")
            unknown = set(doc) - {"version", "env", "secrets", "setup"}
            if unknown:
                raise Refused(f"unknown keys: {', '.join(sorted(unknown))}")
            env = doc.get("env", {})
            if not isinstance(env, dict) or not all(isinstance(v, str) for v in env.values()):
                raise Refused("[env] values must be strings")
            if any(c in v for v in env.values() for c in "\0\n\r"):
                raise Refused("[env] values must be one line, with no NUL")
            secrets = doc.get("secrets", {})
            if not isinstance(secrets, dict) or set(secrets) - {"names"}:
                raise Refused("[secrets] takes only names")
            names = secrets.get("names", [])
            if not isinstance(names, list):
                raise Refused("secrets.names must be a list")
            setup = doc.get("setup", {})
            if not isinstance(setup, dict) or set(setup) - {"run", "timeout_minutes", "check"}:
                raise Refused("[setup] takes run, timeout_minutes and check")
            timeout = setup.get("timeout_minutes", 30)
            if not isinstance(timeout, int) or isinstance(timeout, bool) or not 1 <= timeout <= 240:
                raise Refused("setup.timeout_minutes must be 1 to 240")
            for name in env:
                check_name(name, "env")
            for name in names:
                check_name(name, "secret")
            if len(env) + len(names) > MAX_NAMES:
                raise Refused(f"at most {MAX_NAMES} env and secret names")
            both = set(env) & set(names)
            if both:
                raise Refused(f"names in both [env] and [secrets]: {', '.join(sorted(both))}")
            return {"env": dict(sorted(env.items())), "secrets": sorted(set(names)), "run": commands(setup, "run"),
                    "check": commands(setup, "check"), "timeout_minutes": timeout}


        def checkout():
            """The --repo clone's folder (repo.json beside the bootstrap), when it is under the home folder."""
            try:
                folder = json.loads(read_owned(os.path.join(BOOT, "repo.json")) or b"").get("dir")
            except (OSError, ValueError, AttributeError):
                return None
            if not isinstance(folder, str) or not folder:
                return None
            path = os.path.join(HOME, folder[2:] if folder.startswith("~/") else folder)
            real = os.path.realpath(path)
            # A real folder of this user under the home folder, reached through no symlink.
            if real != os.path.abspath(path) or not real.startswith(os.path.realpath(HOME) + os.sep):
                return None
            try:
                st = os.lstat(real)
            except OSError:
                return None
            return real if os.path.isdir(real) and not os.path.islink(real) and st.st_uid == os.getuid() else None


        REQUEST = re.compile(r"(\d{13}-[0-9a-f]{8})\.(toml|json)\Z")


        def complete_requests(folder):
            """The ids of requests whose `.json` (written last, by the start command) this user can read."""
            try:
                names = os.listdir(folder)
            except FileNotFoundError:
                return []
            ids = [m.group(1) for m in map(REQUEST.match, names) if m and m.group(2) == "json"]
            return sorted(i for i in ids if os.access(os.path.join(folder, i + ".json"), os.R_OK))


        def take_request():
            """The newest request the app staged (`requests/<ms>-<id>.json`, written after its `.toml`): its
            file becomes machine.toml, and it and every older request are removed. None when there is none."""
            folder = os.path.join(D, "requests")
            ids = complete_requests(folder)
            if not ids:
                return None
            def asked(i):
                try:
                    return json.loads(read_owned(os.path.join(folder, i + ".json")) or b"").get("source")
                except (OSError, ValueError, AttributeError):
                    return "auto"
            newest = ids[-1]
            source = asked(newest)
            # The newest upload among the taken requests becomes machine.toml, also when a newer request
            # asks for no file (it then applies the checkout's, else this upload: never an older one).
            for i in reversed(ids):
                staged = os.path.join(folder, i + ".toml")
                if asked(i) == "uploaded" and os.path.isfile(staged) and not os.path.islink(staged):
                    os.replace(staged, os.path.join(D, "machine.toml"))
                    break
            # Only the requests taken here: an upload still being staged (no .json yet) is left alone.
            for i in ids:
                for suffix in (".json", ".toml"):
                    path = os.path.join(folder, i + suffix)
                    if os.path.lexists(path):
                        os.unlink(path)
            return {"id": newest, "source": source}


        def source(repo, asked):
            """The file named in this apply (uploaded), else the checkout's, else the one uploaded before."""
            uploaded = os.path.join(D, "machine.toml")
            if os.path.islink(uploaded):
                raise Refused(f"{uploaded} is a symlink: only the file the app uploaded is applied")
            if asked == "uploaded" and os.path.isfile(uploaded):
                return "uploaded", uploaded
            in_repo = os.path.join(repo, ".cmux/machine.toml") if repo else None
            if in_repo and os.path.lexists(in_repo):
                # The checkout's own file: never a symlink (it could point anywhere), itself or its folder.
                if os.path.islink(in_repo) or os.path.islink(os.path.dirname(in_repo)) or not os.path.isfile(in_repo):
                    raise Refused(f"{in_repo} is a symlink or not a file: the repo's machine config must be a plain file in the checkout")
                return "repo", in_repo
            if os.path.isfile(uploaded):
                return "uploaded", uploaded
            raise Refused("no machine config: pass --machine-config FILE, or add .cmux/machine.toml to the --repo checkout")


        def hook(rc):
            """HOOK first in rc (an interactive-only .bashrc returns early), once; a symlinked rc is left alone."""
            if os.path.islink(rc):
                return f"{rc} is a symlink: add the cmux-machine-env line to it yourself"
            try:
                data = read_owned(rc)
            except FileNotFoundError:
                data = b""
            except OSError:
                return f"{rc} is not a regular file of this user: add the cmux-machine-env line to it yourself"
            if data is None:
                return f"{rc} is over 1 MiB: add the cmux-machine-env line to it yourself"
            text = data.decode("utf-8", "surrogateescape")
            lines = text.split("\n")
            if lines and lines[0] == HOOK:
                return None
            # First, exactly once: a copy further down (after .bashrc's interactive-only return) does nothing,
            # and a comment that only mentions the marker does not count.
            rest = "\n".join(line for line in lines if line != HOOK)
            mode = os.stat(rc).st_mode & 0o777 if os.path.exists(rc) else 0o644
            write(rc, HOOK + "\n" + rest, mode)
            return None


        def private_folder(path):
            """`path` (under HOME) as real folders of this user, each made if missing, none a symlink; the last 0700."""
            here = HOME
            for part in os.path.relpath(path, HOME).split(os.sep):
                here = os.path.join(here, part)
                if not os.path.lexists(here):
                    os.mkdir(here, 0o700)
                st = os.lstat(here)
                if os.path.islink(here) or not os.path.isdir(here) or st.st_uid != os.getuid():
                    raise Refused(f"{here} is not a folder of this user (a symlink?)")
            os.chmod(path, 0o700)


        def delivered():
            """The names in machine-secrets.env: a regular file of this user (machine.env sources nothing else),
            opened without following a link or blocking on a FIFO."""
            try:
                fd = os.open(SECRETS_FILE, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            except OSError:
                return set()
            with os.fdopen(fd) as f:
                st = os.fstat(f.fileno())
                if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_size > 4 << 20:
                    return set()
                return {m.group(1) for m in re.finditer(r"^export ([A-Za-z_][A-Za-z0-9_]*)=", f.read(), re.M)}


        def previous_env_names():
            """The names the current machine.env exports or unsets: none when there is no file; a refusal (never
            "none") when it is there but is not a regular file of this user of at most 4 MiB, since forgetting
            them would leave removed names, a revoked secret too, in every shell that sources the new file."""
            try:
                data = read_owned(ENV_FILE, 4 << 20)
            except FileNotFoundError:
                return set()
            except OSError:
                data = None
            if data is None:
                raise Refused(f"{ENV_FILE} is over 4 MiB or not a regular file of this user: remove it and apply again "
                              "(shells that already loaded it keep its names until they restart)")
            text = data.decode("utf-8", "surrogateescape")
            names = set(re.findall(r"^export ([A-Za-z_][A-Za-z0-9_]*)=", text, re.M))
            for line in re.findall(r"^unset (.+)$", text, re.M):
                names |= {n for n in line.split() if NAME.match(n)}
            return names


        def setup_environment():
            """A clean environment for setup and check: nothing the launching shell exported (a secret it had
            sourced) carries over. `bash -l` then reads the profile, and machine.env skips the secrets file."""
            me = pwd.getpwuid(os.getuid())
            return {"HOME": HOME, "USER": me.pw_name, "LOGNAME": me.pw_name, "SHELL": me.pw_shell or "/bin/sh", "LANG": "C.UTF-8",
                    "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin", "CMUX_MACHINE_SETUP": "1"}


        def secret_values():
            """The delivered values (machine-secrets.env), to mask in everything setup and check print: they run
            as this user and could print the file, and their output is logged and read back over the file API."""
            try:
                fd = os.open(SECRETS_FILE, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            except OSError:
                return []
            with os.fdopen(fd, "rb") as f:
                st = os.fstat(f.fileno())
                if not stat.S_ISREG(st.st_mode):
                    return []  # never sourced (machine.env takes a regular file only)
                if st.st_size > 4 << 20:
                    raise Refused(f"{SECRETS_FILE} is over 4 MiB: deliver the secrets again (cmux cloud deliver-secrets)")
                # Bytes as they are (a CR stays a CR, any byte round-trips), so each value masks as setup prints it.
                text = f.read().decode("utf-8", "surrogateescape")
            if "\0" in text:  # bash drops a NUL when it sources the file, so the value it sets is not the one masked
                raise Refused(f"{SECRETS_FILE} has a NUL byte: deliver the secrets again (cmux cloud deliver-secrets)")
            # Every value, however short (`cmux cloud secret set` takes 8 characters and up; a shorter one was
            # written by hand), as the file holds it too (a setup that prints the file prints that form), and each
            # line of one that spans lines. Only the form the receiver writes: any other line (a hand-written
            # `export A="…"`, whose value no parse here could be sure of) refuses setup instead of leaking it.
            values, at = set(), 0
            for m in re.finditer(r"^export [A-Za-z_][A-Za-z0-9_]*='((?:[^']|'\\'')*)'[ \t\r]*$", text, re.M):
                if text[at:m.start()].strip():
                    break
                at = m.end()
                for form in (m.group(1).replace("'\\''", "'"), m.group(1)):
                    values |= {form} | {line.strip() for line in form.splitlines()}
            if text[at:].strip():
                raise Refused(f"{SECRETS_FILE} has a line cmux did not write (only export NAME='value'): "
                              "deliver the secrets again (cmux cloud deliver-secrets)")
            return sorted({v.encode("utf-8", "surrogateescape") for v in values if v}, key=len, reverse=True)


        class Masked:
            """Writes to `log` with every byte of every value's occurrences masked, each masked run as ***.
            Occurrences are all found in the original bytes (never in output already rewritten) and may overlap,
            so no part of a longer value survives a shorter one's mask. The last (longest value - 1) bytes wait
            for more output or the end: an occurrence starting before them is whole in the buffer, and its bytes
            past the cut stay masked in the next write (`carry`). Overlapping occurrences of one value are taken
            as one run: from an occurrence on, while the text keeps the value's smallest period (overlapping
            occurrences of a value sit a period apart), compared block by block, so a repetitive value costs
            linear time, never a search and a write per occurrence. Up to period - 1 bytes after the last
            whole occurrence of a run may be masked too."""

            def __init__(self, log, values):
                self.log, self.values, self.pending, self.carry, self.periods = log, values, b"", 0, {}
                self.keep = max((len(v) for v in values), default=1) - 1

            def period(self, v):
                """v's smallest period (len(v) minus its longest proper border, by KMP), once per value seen."""
                if v not in self.periods:
                    border, k = [0] * len(v), 0
                    for i in range(1, len(v)):
                        while k and v[i] != v[k]:
                            k = border[k - 1]
                        if v[i] == v[k]:
                            k += 1
                        border[i] = k
                    self.periods[v] = len(v) - border[-1]
                return self.periods[v]

            def write(self, final):
                buf = self.pending
                cut = len(buf) if final else max(0, len(buf) - self.keep)
                cover = bytearray(len(buf))
                end = min(self.carry, len(buf))
                cover[:end] = b"\1" * end
                for v in self.values:
                    i = buf.find(v)
                    while 0 <= i < cut:
                        p, e, step = self.period(v), i + len(v), len(v)
                        while step:  # extend while buf[k] == buf[k - p]: whole blocks, then halving
                            if e + step <= len(buf) and buf[e:e + step] == buf[e - p:e - p + step]:
                                e += step
                            else:
                                step //= 2
                        cover[i:e] = b"\1" * (e - i)
                        end = max(end, e)
                        i = buf.find(v, e - len(v) + 1)  # every occurrence starting before that is inside [i, e)
                out = []
                for run in re.finditer(rb"\x00+|\x01+", bytes(cover[:cut])):
                    out.append(b"***" if run.group()[0] else buf[run.start():run.end()])
                self.pending, self.carry = buf[cut:], max(0, max(end, self.carry) - cut)
                self.log.write(b"".join(out).decode("utf-8", "replace"))
                self.log.flush()

            def feed(self, data):
                self.pending += data
                self.write(final=False)

            def close(self):
                self.write(final=True)


        def group_alive(pgid):
            """Whether any process is left in process group `pgid` (signal 0 checks, sends nothing)."""
            try:
                os.killpg(pgid, 0)
                return True
            except ProcessLookupError:
                return False
            except PermissionError:
                return True


        def run(command, cwd, timeout_s, log):
            script = f'if [ -f "$HOME/.config/cmux/machine.env" ]; then . "$HOME/.config/cmux/machine.env"; fi\nset -eo pipefail\n{command}\n'
            log.write(f"\n== {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {command}\n")
            log.flush()
            env = setup_environment()
            masked = Masked(log, secret_values())
            p = subprocess.Popen(["bash", "-lc", script], cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, start_new_session=True)
            # The output goes through the mask as it comes (select, no thread); the timeout ends the command's
            # whole group: TERM, up to 10 s, then KILL for whatever is left of it (a child that ignored TERM).
            try:
                import selectors
                out = selectors.DefaultSelector()
                out.register(p.stdout, selectors.EVENT_READ)
                deadline, code, stage, eof = time.monotonic() + timeout_s, None, 0, False
                # Until the command has exited and its output is drained: one that closed or redirected its output
                # still runs to its end (or its timeout).
                while not (eof and p.poll() is not None):
                    left = deadline - time.monotonic()
                    if left <= 0:
                        stage += 1
                        if stage == 1:
                            code = 124
                            try:
                                os.killpg(p.pid, signal.SIGTERM)
                            except ProcessLookupError:
                                pass
                            deadline = time.monotonic() + 10
                            continue
                        try:
                            os.killpg(p.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        if stage > 2:
                            break  # a process that escaped the group holds the pipe: never wait on it longer
                        deadline = time.monotonic() + 5
                        continue
                    if eof:
                        time.sleep(min(left, 0.1))
                    elif out.select(timeout=min(left, 1)):
                        chunk = p.stdout.read1(65536)
                        if not chunk:
                            eof = True
                            continue
                        masked.feed(chunk)
                out.close()
                if p.poll() is None:
                    try:
                        os.killpg(p.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                while p.poll() is None:
                    time.sleep(0.05)
                if code == 124:
                    # The whole group, not only bash: a child that outlived it (TERM ignored, output redirected) is
                    # given what is left of its 10 s, then killed.
                    end = time.monotonic() + 10
                    while group_alive(p.pid) and time.monotonic() < end:
                        time.sleep(0.1)
                    try:
                        os.killpg(p.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                code = 124 if code == 124 else p.returncode
                masked.close()
                if code == 124:
                    log.write(f"== timed out after {timeout_s // 60} min\n")
                return code
            except BaseException:
                # Any failure while it runs (a log write, an interrupt): the command's whole group ends with it,
                # before the apply lets go of its locks.
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                while p.poll() is None:  # reaped at once after SIGKILL
                    time.sleep(0.01)
                raise


        def bootstrap_state():
            """Where the uploaded bootstrap is: "running" (its runner wrote `running` with its pid, and that
            process lives), "starting" (no status for this script yet, or `starting`: the start writes it before it
            launches a runner, a retry of a failed one too), or None (finished, its runner died, or none uploaded)."""
            try:
                sha = hashlib.sha256(read_owned(os.path.join(BOOT, "script"), 1 << 20) or b"").hexdigest()
            except OSError:
                return None
            try:
                last = json.loads(read_owned(os.path.join(BOOT, "status.json")) or b"")
            except (OSError, ValueError):
                return "starting"
            if not isinstance(last, dict) or last.get("script_sha256") != sha:
                return "starting"
            state = last.get("state")
            if state in ("done", "failed"):
                return None
            if state == "running":
                return "running" if runner_alive() else None
            return "starting"


        def runner_alive():
            """Whether a bootstrap runner runs: it holds an exclusive flock on `alive` for its whole life, taken
            with a blocking flock, so this probe (shared, non-blocking, released at once) never makes it give up.
            The kernel drops the lock when the runner ends, however it ends: no pid to outlive it."""
            try:
                fd = os.open(os.path.join(BOOT, "alive"), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            except OSError:
                return False
            try:
                if not stat.S_ISREG(os.fstat(fd).st_mode):
                    return False  # the runner replaces anything else with a regular file before it locks it
                fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
                fcntl.flock(fd, fcntl.LOCK_UN)
                return False
            except BlockingIOError:
                return True
            finally:
                os.close(fd)


        def hold_bootstrap_start():
            """A shared flock on ~/.cmux/bootstrap/start.lock, held for the whole apply. A bootstrap start takes it
            exclusively (`flock -w`) from before its first check until it has published `starting`, so it either
            finished that already (and is waited for below) or waits for this apply to end, and fails with a clear
            reason if that takes long: never a bootstrap running beside setup. Returns the descriptor to keep open."""
            os.makedirs(BOOT, mode=0o700, exist_ok=True)
            st = os.lstat(BOOT)
            if os.path.islink(BOOT) or not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
                raise Refused(f"{BOOT} is not a folder of this user (a symlink?)")
            fd = os.open(os.path.join(BOOT, "start.lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o644)
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
                os.close(fd)
                raise Refused(f"{BOOT}/start.lock is not a regular file of this user")
            deadline = time.monotonic() + BOOTSTRAP_WAIT_S
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    return fd
                except BlockingIOError:
                    if time.monotonic() > deadline:
                        raise Refused("a bootstrap start held its lock for 3 h") from None
                    time.sleep(0.2)


        def wait_for_bootstrap():
            """Under ``hold_bootstrap_start``: a bootstrap runner (a --repo clone, the lane bootstrap) finishes
            before the config applies, while it runs (``runner_alive``) or its start said `starting` (up to
            STARTING_S for a start that died). The runner's own lock is never touched."""
            if not os.path.exists(os.path.join(BOOT, "script")):
                return  # no bootstrap on this machine
            if not runner_alive() and bootstrap_state() is None:
                return
            status("waiting", waiting_for="bootstrap")
            deadline, quiet_since = time.monotonic() + BOOTSTRAP_WAIT_S, time.monotonic()
            while time.monotonic() < deadline:
                state = bootstrap_state()
                if runner_alive():
                    quiet_since = time.monotonic()
                elif state is None or time.monotonic() - quiet_since >= STARTING_S:
                    return
                time.sleep(1)
            raise Refused("the bootstrap still runs after 3 h")


        def pending_requests():
            return bool(complete_requests(os.path.join(D, "requests")))


        def main():
            """Applies the staged requests (newest wins) under the lock, then any staged while it ran (their start saw
            the lock held and said `running`), also one staged just as the lock goes. With nothing staged it does
            nothing: every apply the app starts stages a request (a no-file one says `auto`). Any failure before or
            between applies still ends in a failed status."""
            try:
                own_folders()
                lock = os.open(os.path.join(D, "lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                st = os.fstat(lock)
                if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
                    raise Refused(f"{os.path.join(D, 'lock')} is not a file of this user")
                code = 0
                while pending_requests():
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        return code  # the applier that holds it takes what is staged
                    try:
                        while (request := take_request()) is not None:
                            code = apply_once(request)
                    finally:
                        fcntl.flock(lock, fcntl.LOCK_UN)
                return code
            except Refused as e:
                status("failed", error=str(e))
                return 1
            except Exception as e:  # noqa: BLE001  a startup error ends in a status too, never a stale one
                status("failed", error=f"{type(e).__name__}: {e}"[:500])
                return 1


        def own_folders():
            """~/.cmux, ~/.cmux/machine-config and its requests folder are real folders of this user."""
            for path in (os.path.dirname(D), D, os.path.join(D, "requests")):
                st = os.lstat(path) if os.path.lexists(path) else None
                if st is None or os.path.islink(path) or not os.path.isdir(path) or st.st_uid != os.getuid():
                    raise Refused(f"{path} is not a folder of this user (a symlink?)")


        def apply_once(request):
            report = {"request": request["id"]}
            start_lock = None
            try:
                start_lock = hold_bootstrap_start()
                wait_for_bootstrap()
                status("running", **report)
                repo = checkout()
                kind, path = source(repo, request["source"])
                report.update(source=kind, path=path)
                try:
                    data = read_owned(path, MAX_BYTES)
                except OSError:
                    raise Refused(f"{path} is not a regular file of this user") from None
                if data is None:
                    raise Refused(f"{path} is over {MAX_BYTES // 1024} KiB")
                try:
                    config = parse(data.decode("utf-8"))
                except UnicodeDecodeError:
                    raise Refused(f"{path} is not UTF-8") from None
                report["config_sha"] = hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()
                private_folder(CONF)
                lines = ["# cmux machine env (cmux cloud apply-machine-config; source in ~/.cmux/machine-config/status.json), rewritten on every apply"]
                # Secret values first, for shells and agents, never [setup] (whose output is logged, and its tail
                # read back through the Cloud file API): the applier runs setup with CMUX_MACHINE_SETUP=1. A name
                # the file still has but the config no longer declares is unset; then [env], so a stale secret
                # never overrides a declared value.
                # Every declared secret name is unset first, so a shell that sources this again drops a value that
                # was revoked (no longer in machine-secrets.env), and a later apply knows the names (previous_env_names).
                if config["secrets"]:
                    lines += ["unset " + " ".join(config["secrets"])]
                lines += ['if [ -z "${CMUX_MACHINE_SETUP:-}" ] && [ -f "$HOME/.config/cmux/machine-secrets.env" ] && [ ! -L "$HOME/.config/cmux/machine-secrets.env" ]; then . "$HOME/.config/cmux/machine-secrets.env"; fi']
                stale = sorted(delivered() - set(config["secrets"]))
                if stale:
                    lines += ["unset " + " ".join(stale)]
                # Names an earlier apply exported (or already unset) and this config no longer declares: a shell
                # that loaded the old file keeps them otherwise.
                # All of them, every time (never a newest one dropped): previous_env_names reads them back.
                gone = sorted(previous_env_names() - set(config["env"]) - set(config["secrets"]))
                if gone:
                    lines += ["unset " + " ".join(gone)]
                lines += [f"export {k}={quoted(v)}" for k, v in config["env"].items()]
                text = "\n".join(lines) + "\n"
                if len(text.encode()) > 4 << 20:  # the next apply must be able to read it back (previous_env_names)
                    raise Refused(f"{ENV_FILE} would be over 4 MiB: remove it and apply again")
                write(ENV_FILE, text)
                rcs = [os.path.join(HOME, ".profile"), os.path.join(HOME, ".bashrc")]
                # bash reads the first of these that exists instead of .profile for a login shell.
                for login in (".bash_profile", ".bash_login"):
                    if os.path.exists(os.path.join(HOME, login)):
                        rcs.append(os.path.join(HOME, login))
                # zsh reads ~/.zshenv for every shell, `ssh host cmd` too. (bash run by sshd for a command reads
                # ~/.bashrc: Debian and Ubuntu build bash with SSH_SOURCE_BASHRC, so .bashrc's first line covers it.)
                if os.path.basename(pwd.getpwuid(os.getuid()).pw_shell or "") == "zsh" or os.path.exists(os.path.join(HOME, ".zshenv")):
                    rcs.append(os.path.join(HOME, ".zshenv"))
                report["hooks_pending"] = [p for p in map(hook, rcs) if p]
                report["env"] = list(config["env"])
                have = delivered()
                report["secrets"] = {"declared": config["secrets"], "missing": [n for n in config["secrets"] if n not in have]}
                cwd = repo or HOME
                setup_sha = hashlib.sha256(json.dumps({k: config[k] for k in ("env", "run", "timeout_minutes")} | {"cwd": cwd}, sort_keys=True).encode()).hexdigest()
                try:
                    last = json.loads(read_owned(os.path.join(D, "state.json")) or b"")
                    last = last if isinstance(last, dict) else {}
                except (OSError, ValueError):
                    last = {}
                setup = {"state": "none" if not config["run"] else "unchanged", "setup_sha": setup_sha}
                log_path = os.path.join(D, "setup.log")
                with os.fdopen(os.open(log_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600), "a") as log:
                    if not stat.S_ISREG(os.fstat(log.fileno()).st_mode):
                        raise Refused(f"{log_path} is not a regular file")
                    os.fchmod(log.fileno(), 0o600)
                    if config["run"] and not (last.get("setup_sha") == setup_sha and last.get("ok")):
                        # Not ok until it finishes: an interrupted run is never taken for an earlier success.
                        write(os.path.join(D, "state.json"), json.dumps({"setup_sha": setup_sha, "ok": False}) + "\n")
                        setup["state"] = "ok"
                        for index, command in enumerate(config["run"]):
                            status("running", step=index, **report)
                            code = run(command, cwd, config["timeout_minutes"] * 60, log)
                            if code != 0:
                                setup.update(state="failed", failing_index=index, failing_command=command, exit_code=code)
                                break
                        write(os.path.join(D, "state.json"), json.dumps({"setup_sha": setup_sha, "ok": setup["state"] == "ok"}) + "\n")
                    checks = [{"command": c, "exit_code": run(c, cwd, config["timeout_minutes"] * 60, log)} for c in config["check"]]
                # No output in the status: it is read back through the Cloud file API (cmux cloud deliver-secrets reads
                # it for the declared names), and setup's output could hold a value however it is masked. The log
                # stays on the machine: read it in a terminal there.
                setup["log"] = log_path
                report.update(setup=setup, checks=checks)
                status("failed" if setup["state"] == "failed" else "done", **report)
                return 1 if setup["state"] == "failed" else 0
            except Refused as e:
                status("failed", error=str(e), **report)
                return 1
            except Exception as e:  # noqa: BLE001  any other failure still ends in a status, never a stuck "running"
                status("failed", error=f"{type(e).__name__}: {e}"[:500], **report)
                return 1
            finally:
                if start_lock is not None:
                    os.close(start_lock)  # a waiting bootstrap start may go now


        if __name__ == "__main__":
            sys.exit(main())
        """#
}
