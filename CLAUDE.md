This project is called cmux. cmux is a web app that spawns Claude Code, Codex CLI, Gemini CLI, Amp, Opencode, and other coding agent CLIs in parallel across multiple tasks. For each run, cmux spawns an isolated openvscode instance via Docker or a configurable sandbox provider. The openvscode instance by default opens the git diff UI and a terminal with the running dev server (configurable via devcontainer.json).

# Config

Use bun to install dependencies and run the project.
`./scripts/dev.sh` will start the project. Optional flags:

- `--force-docker-build`: Rebuild worker image even if cached.

If you make code changes, run `bun check` and fix errors after completing a task.

# Backend

This project uses Convex and Hono.
Hono is defined in apps/www/lib/hono-app.ts as well as apps/www/lib/routes/\*
The Hono app generates a client in @cmux/www-openapi-client. This is automatically re-generated when the dev-server is running. If you change the Hono app (and the dev server isn't running), you should run `(cd apps/www && bun run generate-openapi-client)` to re-generate the client. Note that the generator is in www and not www-openapi-client.
We MUST force validation of requests that do not have the proper `Content-Type`. Set the value of `request.body.required` to `true`. For example:

```ts
app.openapi(
  createRoute({
    method: "post",
    path: "/books",
    request: {
      body: {
        content: {
          "application/json": {
            schema: z.object({
              title: z.string(),
            }),
          },
        },
        required: true, // <== add
      },
    },
    responses: {
      200: {
        description: "Success message",
      },
    },
  }),
  (c) => c.json(c.req.valid("json"))
);
```

## Convex

Schemas are defined in packages/convex/convex/schema.ts.
If you're working in Convex dir, you cannot use node APIs/import from "node:\*"
Use crypto.subtle instead of node:crypto
Exception is if the file defines only actions and includes a "use node" directive at the top of the file
To query Convex data during development, first cd into packages/convex, and run `bunx convex data <table> --format jsonl | rg "pattern"` (e.g., `bunx convex data sessions --format jsonl | rg "mn7abc123"`).

## Sandboxes

This project uses Morph sandboxes for running Claude Code/Codex/other coding CLIs inside.
To inspect Morph instances, use the morphcloud cli with the corresponding morphvm\_ id:

```bash
uvx --env-file .env morphcloud instance exec morphvm_q11mhv3p "ls"
🏁  Command execution complete!
--- Stdout ---
server.log
xagi-server
--- Exit Code: 0 ---
```

Morph snapshots capture RAM state. So after snapshot, running processes will still be running.
To modify and rebuild all snapshots, edit `./scripts/snapshot.py` and run `uv run --env-file .env ./scripts/snapshot.py`
After building a snapshot, you should always use the `say` command to notify the user to verify the changes that were made to the snapshot.
After the say command, you should give the user a table with the snapshot preset and vnc/vscode/xterm urls.
.env sometimes might not exist, but you can still run the script if `echo $MORPH_API_KEY` works.

# Frontend

This project uses React, TanStack Router, TanStack Query, Shadcn UI, and Tailwind CSS.
Always use tailwind `neutral` instead of `gray` for gray colors.
Always support both light and dark mode.

# Misc

Always use "node:" prefixes for node imports
Do not use the "any" type
Do not use casts unless absolutely necessary. Most casts may be solved with zod parsing.
Don't modify README.md unless explicitly asked
Do not write docs unless explicitly asked
Do not use dynamic imports unless absolutely necessary. Exceptions include when you're following existing patterns in the codebase
We're using Node 24, which supports global fetch
When using try/catch, never suppress errors. Always console.error any errors.

# Tests

Use vitest
Place test files next to the file they test using a .test.ts extension
Do not use mocks
Do not do early returns (eg. skipping tests if we're missing environment variables)
Make tests resilient

## Logs

When running `./scripts/dev.sh`, service logs are written to `logs/{type}.log`:

- docker-compose.log: Output from `.devcontainer` Docker Compose stack. Hidden from console by default; use `--show-compose-logs` to stream.
- convex-dev.log: Convex development server (`bunx convex dev`).
- server.log: Backend dev server in `apps/server`.
- client.log: Frontend dev server in `apps/client` (Vite).

Log files are overwritten on each run. Use `tail -f logs/<file>` to follow live output.

## cmux/dmux cli

The cmux cli is written in Rust.
If working on the cmux cli (dmux in development mode), first read packages/sandbox/AGENTS.md