#!/usr/bin/env python3
"""Pane-bound Claude/Codex hooks for the ssh-tmux control stream (Python 3.8+)."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import uuid

EVENTS = {
    'SessionStart': ('session_start', 'idle'),
    'UserPromptSubmit': ('user_prompt_submit', 'working'),
    'PreToolUse': ('pre_tool_use', 'working'),
    'PostToolUse': ('post_tool_use', 'working'),
    'PermissionRequest': ('permission_request', 'blocked'),
    'Stop': ('stop', 'idle'),
    'SessionEnd': ('session_end', 'clear'),
}
CODEX_MANAGEMENT = set('a apply app app-server archive cloud completion debug delete doctor exec-server features help login logout mcp mcp-server plugin remote-control review sandbox unarchive update'.split())
CODEX_VALUES = set('-c --config -m --model -p --profile -C --cd --remote -a --ask-for-approval -s --sandbox --output-last-message --enable --disable --add-dir -i --image --local-provider --remote-auth-token-env --output-schema --color'.split())


def session_launch(agent, args):
    """Skip management/help invocations and explicit hook opt-outs."""
    values = CODEX_VALUES if agent == 'codex' else set('--model --settings --permission-mode --output-format --input-format --resume --allowedTools --disallowedTools'.split())
    positional = False
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == '--':
            break
        if arg in ('-h', '--help', '-V', '--version'):
            return False
        if agent == 'claude' and arg == '--disable-slash-commands':
            pass
        if arg in values:
            if agent == 'codex' and arg == '--disable' and args[index + 1:index + 2] == ['hooks']:
                return False
            index += 2
            continue
        if arg == '--disable=hooks':
            return False
        if not arg.startswith('-') and not positional:
            management = CODEX_MANAGEMENT if agent == 'codex' else {'auth', 'doctor', 'install', 'mcp', 'plugin', 'setup-token', 'update', 'upgrade'}
            if arg in management:
                return False
            positional = True
        index += 1
    return os.environ.get('CMUX_CODEX_HOOKS_DISABLED' if agent == 'codex' else 'CMUX_CLAUDE_HOOKS_DISABLED') != '1'


def hoist_codex_globals(args):
    """Codex exec/resume/fork carry their own config flags; keep our hook layer."""
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == '--':
            return args
        if arg.startswith('-'):
            index += 2 if arg in CODEX_VALUES else 1
        elif arg in ('exec', 'e', 'resume', 'fork'):
            break
        else:
            return args
    if index >= len(args):
        return args
    head, tail = args[:index], [args[index]]
    index += 1
    while index < len(args):
        arg = args[index]
        if arg == '--':
            tail.extend(args[index:])
            break
        count = 2 if arg in CODEX_VALUES and index + 1 < len(args) else 1
        target = head if arg in ('-c', '--config', '--enable', '--disable') or arg.startswith(('--config=', '--enable=', '--disable=')) or (arg.startswith('-c') and len(arg) > 2) else tail
        target.extend(args[index:index + count])
        index += count
    return head + tail


def tmux_call(context, *args):
    return subprocess.check_output([context['tmux'], '-S', context['socket'], *args], stderr=subprocess.DEVNULL, timeout=2).decode().rstrip('\n')


def report(context, state):
    # A late hook from an older invocation must not overwrite its replacement.
    if tmux_call(context, 'show-options', '-pqv', '-t', context['pane'], '@cmux_agent_owner') != context['owner']:
        return
    payload = '' if state == 'clear' else json.dumps({'agent': context['agent'], 'state': state}, separators=(',', ':'))
    tmux_call(context, 'set-option', '-p', '-t', context['pane'], '@cmux_agent', payload)


def hook_command(context, state):
    encoded = base64.b64encode(json.dumps(context).encode()).decode()
    return shlex.join([sys.executable, str(Path(__file__).resolve()), '--hook', encoded, state]) + ' 2>/dev/null || :; printf \'{}\''


def launch(agent, args):
    directory = Path(__file__).resolve().parent
    shim_dir = directory / 'bin' if (directory / 'bin').is_dir() else directory
    # Only remove our shims; keep unrelated launch wrappers and user PATH entries.
    path = os.pathsep.join(p for p in os.environ.get('PATH', '').split(os.pathsep) if p and Path(p).resolve() != shim_dir.resolve())
    executable = shutil.which(agent, path=path)
    if not executable:
        return 127
    os.environ['PATH'] = path
    injected = []
    try:
        pane = os.environ.get('TMUX_PANE', '')
        socket = os.environ.get('TMUX', '').rsplit(',', 2)[0]
        tmux = shutil.which('tmux')
        if re.fullmatch(r'%[0-9]+', pane) and socket and tmux and session_launch(agent, args):
            context = dict(agent=agent, pane=pane, socket=socket, tmux=tmux, owner=uuid.uuid4().hex)
            tmux_call(context, 'set-option', '-p', '-t', pane, '@cmux_agent_owner', context['owner'])
            if agent == 'codex':
                injected = ['--enable', 'hooks']
                # Codex splits a -c key on every '.', even inside quotes, so the
                # trust entries go in one inline table at hooks.state.
                trust = []
                for event, (label, state) in EVENTS.items():
                    command = hook_command(context, state)
                    timeout = 3 if event == 'SessionEnd' else 5
                    identity = {'event_name': label, 'hooks': [{'type': 'command', 'command': command, 'timeout': timeout, 'async': False}]}
                    digest = hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
                    handler = '{hooks=[{type="command",command=' + json.dumps(command, ensure_ascii=False) + ',timeout=' + str(timeout) + '}]}'
                    injected += ['-c', 'hooks.' + event + '=[' + handler + ']']
                    key = '/<session-flags>/config.toml:' + label + ':0:0'
                    trust.append(json.dumps(key) + '={trusted_hash="sha256:' + digest + '"}')
                injected += ['-c', 'hooks.state={' + ','.join(trust) + '}']
                args = hoist_codex_globals(args)
            else:
                hooks = {event: [{'hooks': [{'type': 'command', 'command': hook_command(context, state), 'timeout': 5}]}] for event, (_, state) in EVENTS.items()}
                # Claude merges settings hooks with the user's existing settings.
                injected = ['--settings', json.dumps({'hooks': hooks})]
            report(context, 'idle')
    except (OSError, ValueError, subprocess.SubprocessError):
        injected = []
    os.execv(executable, [executable, *injected, *args])


def install(session, encoded):
    """Runs in-band via tmux run-shell; never opens another SSH connection."""
    data = base64.b64decode(encoded)
    directory = Path.home() / '.local/share/cmux/tmux-agent' / hashlib.sha256(data).hexdigest()[:16]
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    script = directory / 'agent.py'
    script.write_bytes(data)
    script.chmod(0o600)
    bin_dir = directory / 'bin'
    bin_dir.mkdir(mode=0o700, exist_ok=True)
    for agent in ('claude', 'codex'):
        shim = bin_dir / agent
        shim.write_text('#!/bin/sh\nexec ' + shlex.join([sys.executable, str(script), '--launch', agent]) + ' "$@"\n')
        shim.chmod(0o700)
    integration = directory / 'init.sh'
    integration.write_text('export PATH=' + shlex.quote(str(bin_dir)) + ':"$PATH"\n')
    # Existing shells can source this stable path without changing startup files.
    stable = directory.parent / 'init.sh'
    stable.write_text('. ' + shlex.quote(str(integration)) + '\n')
    context = dict(tmux=shutil.which('tmux'), socket=os.environ['TMUX'].rsplit(',', 2)[0])
    previous = tmux_call(context, 'show-options', '-Aqv', '-t', session, 'default-command')
    owned = tmux_call(context, 'show-options', '-Aqv', '-t', session, '@cmux_agent_default_command')
    shell = tmux_call(context, 'show-options', '-Aqv', '-t', session, 'default-shell') or os.environ.get('SHELL', '/bin/sh')
    if previous and previous != owned:
        source_existing_shells(context, session, shell, stable, bin_dir)
        return  # Preserve a deliberate user command.
    command = shlex.join([sys.executable, str(script), '--shell', shell])
    tmux_call(context, 'set-option', '-t', session, 'default-command', command)
    tmux_call(context, 'set-option', '-t', session, '@cmux_agent_default_command', command)
    source_existing_shells(context, session, shell, stable, bin_dir)


def source_existing_shells(context, session, shell, stable, bin_dir):
    """Add the shim to idle shells that predate the mirror attachment.

    A tmux session's environment only reaches processes started later, so
    changing `default-command` cannot update the shell already occupying the
    initial pane. Restrict the one-shot source to a pane whose foreground
    command is a known shell and whose last line still looks like an empty
    prompt; never interrupt a running program or a line with user input.
    """
    shell_name = Path(shell).name
    shell_names = {shell_name, 'bash', 'zsh', 'sh', 'dash', 'fish', 'ksh'}
    try:
        rows = tmux_call(
            context, 'list-panes', '-s', '-t', session, '-F',
            '#{pane_id}\t#{pane_current_command}\t#{pane_dead}',
        ).splitlines()
    except (OSError, subprocess.SubprocessError):
        return
    for row in rows:
        pane, current, dead = (row.split('\t', 2) + ['', '', ''])[:3]
        if not re.fullmatch(r'%[0-9]+', pane) or dead == '1' or Path(current).name not in shell_names:
            continue
        try:
            capture = tmux_call(context, 'capture-pane', '-p', '-t', pane, '-S', '0', '-E', '-1')
        except (OSError, subprocess.SubprocessError):
            continue
        lines = [re.sub(r'\x1b\[[0-9;]*m', '', value) for value in capture.rstrip('\r\n').splitlines()]
        if not lines:
            continue
        try:
            cursor_y = int(tmux_call(context, 'display-message', '-p', '-t', pane, '#{cursor_y}'))
        except (ValueError, OSError, subprocess.SubprocessError):
            cursor_y = len(lines) - 1
        line = lines[cursor_y] if 0 <= cursor_y < len(lines) else lines[-1]
        # The trailing space is part of the shell prompt. Requiring it avoids
        # treating an unfinished command ending in '#' or '%' as an empty prompt.
        if not re.search(r'(?:[$%#]|❯|➜)\s+$', line):
            continue
        if Path(current).name == 'fish':
            source = 'set -gx PATH ' + shlex.quote(str(bin_dir)) + ' $PATH'
        else:
            source = '. ' + shlex.quote(str(stable))
        tmux_call(context, 'send-keys', '-t', pane, '-l', source)
        tmux_call(context, 'send-keys', '-t', pane, 'Enter')


def shell_launch(shell):
    directory = Path(__file__).resolve().parent
    shim_dir = directory / 'bin' if (directory / 'bin').is_dir() else directory
    integration = '. ' + shlex.quote(str(directory / 'init.sh'))
    name = Path(shell).name
    if name == 'bash':
        command = integration + '; exec ' + shlex.join([shell, '-i'])
        os.execv(shell, [shell, '-lic', command])
    if name == 'zsh':
        command = integration + '; exec ' + shlex.join([shell, '-i'])
        os.execv(shell, [shell, '-lic', command])
    if name == 'fish':
        command = 'set -gx PATH ' + shlex.quote(str(shim_dir)) + ' $PATH'
        os.execv(shell, [shell, '-i', '-C', command])
    os.environ['PATH'] = str(shim_dir) + os.pathsep + os.environ.get('PATH', '')
    os.execv(shell, [shell, '-l'])


def main():
    mode = sys.argv[1]
    if mode == '--install':
        install(sys.argv[2], sys.argv[3])
    elif mode == '--launch':
        return launch(sys.argv[2], sys.argv[3:])
    elif mode == '--hook':
        # Drain without copying prompt contents into status or files.
        while sys.stdin.buffer.read(65536):
            pass
        try:
            report(json.loads(base64.b64decode(sys.argv[2])), sys.argv[3])
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    elif mode == '--shell':
        shell_launch(sys.argv[2])
    return 0


if __name__ == '__main__':
    sys.exit(main())
