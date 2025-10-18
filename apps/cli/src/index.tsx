import process from "node:process";
import React from "react";
import { Command } from "commander";
import { render } from "ink";
import { App } from "./app";
import {
  listEnvironments,
  listTeams,
  login,
  logout,
} from "./commands";

async function runInteractive(): Promise<void> {
  const instance = render(<App />);
  await instance.waitUntilExit();
}

async function runProgram(): Promise<void> {
  if (process.argv.length <= 2) {
    await runInteractive();
    return;
  }

  const program = new Command();

  program
    .name("cmux-cli")
    .description("CMUX CLI for authenticating and listing environments");

  program
    .command("login")
    .description("Authenticate with Stack Auth and persist credentials")
    .option("--quiet", "Suppress status output", false)
    .action(async (options: { quiet?: boolean }) => {
      await login({ quiet: options.quiet });
    });

  program
    .command("logout")
    .description("Clear persisted credentials")
    .action(async () => {
      await logout();
    });

  program
    .command("teams")
    .description("List teams available to the authenticated user")
    .option("--quiet", "Suppress status output", false)
    .action(async (options: { quiet?: boolean }) => {
      await listTeams({ quiet: options.quiet });
    });

  program
    .command("environments")
    .description("List environments for a given team")
    .requiredOption("-t, --team <slugOrId>", "Team slug or ID")
    .option("--json", "Output JSON")
    .option("--quiet", "Suppress status output", false)
    .action(
      async (options: {
        quiet?: boolean;
        team: string;
        json?: boolean;
      }) => {
        await listEnvironments({
          quiet: options.quiet,
          team: options.team,
          json: options.json,
        });
      },
    );

  await program.parseAsync(process.argv);
}

void runProgram().catch((error) => {
  const message =
    error instanceof Error
      ? error.message
      : "Unknown error while running the CLI.";
  // Ensure cursor visibility before exiting due to an error.
  process.stderr.write("\u001B[?25h");
  console.error(message);
  process.exitCode = 1;
});
