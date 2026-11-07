---
name: cmux-sudo
description: "Run one command as root through the person's approval: the request_elevation tool shows them a card with the exact command and a password field, and cmux runs sudo for you. Use when a step truly needs root (fs_usage, dtruss, powermetrics, a protected log, or a fix the person asked for), when sudo asks for a password, or when the person offers to type their password."
---

# Running a command as root

You never get the person's password, and you never ask for it. Call `request_elevation`
instead. cmux shows the person a card with the exact command, this chat and your reason, and a
password field. Only the person can answer that card; you cannot. If they approve, cmux runs
`sudo -- argv` itself and gives you back only `exitCode`, `stdout` and `stderr`.

## When to use it

- A read-only diagnostic that needs root: `fs_usage`, `dtruss`, `powermetrics`, `opensnoop`, or
  reading a log or file only root can read.
- A real fix the person asked for that needs root, such as a system setting, a launch daemon or
  a file under `/Library` or `/etc`.
- Don't use it for convenience, to get around a permission refusal from cmux, or for anything
  the person did not ask for. A plain shell command works for anything that does not need root.

## How to ask

- Pass `argv` as a list, such as `["fs_usage", "-w", "-f", "filesys", "-t", "10"]`. It runs with
  no shell, so pipes, `&&`, globs and redirects don't work. Run one command and filter its
  output yourself afterwards.
- Every argument is printable ASCII, so the card shows exactly what runs. A path or text with
  other characters is refused; put it in a file and pass the file's path.
- Make the command end on its own: `fs_usage -t SECONDS`, `powermetrics -n 1`. Set
  `timeoutSecs` (1 to 600, default 60). A command still running at the timeout is stopped,
  and `timedOut` is true. `stillRunning` is then `"yes"` when part of it ignored the stop and
  still runs as root, or `"unknown"` when the group stopped but a detached process can't be
  ruled out. Tell the person in either case.
- Write `reason` as one plain sentence: what you will learn or fix with the command.
- The command runs on this chat's own machine. Leave `host` out, or set it to this machine's
  name. To run as root on another machine, ask from a chat on that machine.
- Each approval covers one command. No sudo login is left behind afterwards, so the next
  command needs a new card.

## Answers

- `approved`: the command ran. Read `exitCode`, `stdout` and `stderr`. A wrong password shows
  as a failed `exitCode` with sudo's message in `stderr`. Ask again only if the person wants
  to retry.
- `denied`: final. Don't ask again for this command or a variation of it unless the person asks
  you to. Find another way, or say what you could not do.
- `cancelled`: the card closed without an answer (the turn ended, or 10 minutes passed). Ask
  again only if the person still wants the command run.

## Never

- Never ask for the password in chat, and never accept it there. If the person types it in
  the chat anyway, don't repeat it or use it. Tell them the card is the place for it.
- Never put a password in a command, a file, an environment variable, `sudo -S` input or a
  script of your own.
- Never write a `sudo` of your own, or change sudoers, to avoid the card.
