# Security

## Reporting a vulnerability

Email **founders@manaflow.com**. Put "security" in the subject line.

Do not open a public issue for a vulnerability, and do not post it in Discord.
A public report means everyone running cmux learns about it at the same time we
do, and cmux runs your shell.

Tell us what you can:

- What an attacker can do, and what they need to start (a local account, a
  malicious escape sequence, a crafted repository, a hostile server on the other
  end of `cmux ssh`).
- The cmux version and how you installed it.
- Steps or a proof of concept. A rough one is fine.

Use test accounts and redact credentials, personal data, and unrelated terminal
contents. Do not send live tokens or private keys. If sensitive evidence is
needed, describe what you have so we can arrange how to share it privately.

You do not need a CVSS score or a written-up advisory. A paragraph that says
"a workspace name containing this string runs the rest of it as a command" is a
complete report.

## What happens next

We reply as fast as we can, and we tell you what we think the impact is even
when that differs from your read. If it holds up we fix it and say so in the
release notes. We credit you by name or handle unless you would rather we
did not, and we will not tell you to stay quiet for months.

If you get no reply in a week, send it again or ping in
[Discord](https://discord.gg/xsgFEVrWCZ) asking someone to check the inbox.
Saying "I emailed you about a security issue" in public is fine and helpful; the
details are the part to keep out of public threads.

## Scope

cmux is a terminal, so a lot of alarming-looking behavior is the job: it runs
the commands you type, it runs your shell config, and it runs agents you have
told it to run. Things we do consider vulnerabilities:

- Escaping the sandbox of a cmux Cloud VM, or reaching another tenant's data.
- Terminal output that runs code without the user asking: an escape sequence, a
  file name, a git branch name, a pasted string, an agent's output.
- Anything that leaks credentials or tokens outside the machine, including into
  logs we upload.
- Authentication and authorization mistakes in `cmux ssh`, the relay, or the
  web dashboard.
- Privilege escalation through the update path or the installed helpers.

Things we do not: `cmux` running a command that you typed, a shell config that
does something surprising, or an agent doing something you approved.

## Supported versions

We fix security issues in the latest release, the RC channel and NIGHTLY. There
is no long-term support branch to backport to.

## Security documentation

- [Threat model outline](docs/security/threat-model.md): assets, trust boundaries,
  threats, and limits of the protections cmux provides.
- [Incident response overview](docs/security/incident-response.md): how reports,
  fixes, and public communication fit together. Operational response procedures
  and active incident evidence are maintained privately.
