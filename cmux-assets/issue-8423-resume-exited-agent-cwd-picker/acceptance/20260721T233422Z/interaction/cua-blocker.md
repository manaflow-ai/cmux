# Visual evidence blocker

The documented `cua-ssh` path was attempted against `local`. No substitute screenshot or fabricated video was produced.

`cua-ssh doctor local` reported:

```text
transport                    pass   local host, SSH bypassed
remote-home                  pass   /Users/austinwang
windows                      pass   14 visible normal windows
screen-recording-preflight   warn   direct local Screen Recording denied
gui-recording-helper         warn   no approved GUI recording helper found
sky-bundle                   fail   missing executable codex; missing Codex Computer Use.app/SkyComputerUse binaries; missing /Applications/Codex.app identity bridge
sky-auth                     pass   ~/.codex/auth.json present
sky-app-server               fail   exit status 1
```

Full-screen recording refusal:

```text
cua-ssh: screen recording permission is denied on local; refusing to start a recording because macOS will produce background-only frames. Approve Screen & System Audio Recording for the responsible process, then retry.
```

Full-desktop screenshot refusal:

```text
cua-ssh: screen recording permission is denied on local; refusing to take a screenshot because macOS can produce background-only frames. Approve Screen & System Audio Recording for the responsible process, then retry.
```

SIP was enabled, there was no MDM enrollment, and no approved GUI recording helper was available. Runtime evidence therefore uses the tag-bound read-screen API, DEBUG decisions, exact process tree, and shell sentinel rather than visual artifacts.
