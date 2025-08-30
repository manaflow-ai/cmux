"use client";

import { ClientIcon } from "@/components/client-icon";
import CmuxLogo from "@/components/logo/cmux-logo";
import {
  Check,
  Cloud,
  Copy,
  GitBranch,
  Github,
  GitPullRequest,
  Star,
  Terminal,
  Users,
  Zap,
} from "lucide-react";
import Image from "next/image";
import { useState } from "react";

export default function LandingPage() {
  const [copiedCommand, setCopiedCommand] = useState<string | null>(null);

  const copyToClipboard = (text: string) => {
    navigator.clipboard.writeText(text);
    setCopiedCommand(text);
    setTimeout(() => setCopiedCommand(null), 2000);
  };

  return (
    <div className="min-h-dvh bg-background text-foreground overflow-y-auto">
      {/* Announcement bar */}
      <div className="w-full bg-blue-300 px-3 py-1 text-center font-medium text-black">
        <span>
          cmux is{" "}
          <a
            href="https://github.com/manaflow-ai/cmux"
            target="_blank"
            rel="noopener noreferrer"
            className="text-black underline decoration-blue-600 decoration-dotted underline-offset-4 hover:decoration-solid"
          >
            open source on GitHub
          </a>
          .
        </span>{" "}
        <span className="whitespace-nowrap ml-2">
          <a
            href="#requirements"
            className="whitespace-nowrap bg-black px-2 py-0.5 rounded-sm font-semibold text-blue-300 hover:text-blue-200"
          >
            See requirements
          </a>
        </span>
      </div>

      {/* Header */}
      <header className="mb-6 bg-neutral-950/80 backdrop-blur top-0 z-40 border-b border-neutral-900">
        <div className="container max-w-5xl mx-auto px-2 sm:px-3 py-2.5">
          <div className="grid w-full grid-cols-[auto_1fr] grid-rows-1 items-center gap-2">
            <a
              aria-label="Go to homepage"
              className="col-start-1 col-end-2 inline-flex items-center"
              href="/"
            >
              <CmuxLogo height={40} label="cmux" showWordmark />
            </a>
            <div className="col-start-2 col-end-3 flex items-center justify-end gap-2 sm:gap-3">
              <nav aria-label="Main" className="hidden md:flex items-center">
                <ul className="flex flex-wrap items-center gap-x-2">
                  <li>
                    <a
                      className="font-semibold text-white hover:text-blue-400 transition"
                      href="#about"
                    >
                      About
                    </a>
                  </li>
                  <li className="text-neutral-700 px-1" role="presentation">
                    |
                  </li>
                  <li>
                    <a
                      className="font-semibold text-white hover:text-blue-400 transition"
                      href="#features"
                    >
                      Features
                    </a>
                  </li>
                  <li className="text-neutral-700 px-1" role="presentation">
                    |
                  </li>
                  <li>
                    <a
                      className="font-semibold text-white hover:text-blue-400 transition"
                      href="#requirements"
                    >
                      Requirements
                    </a>
                  </li>
                  <li className="text-neutral-700 px-1" role="presentation">
                    |
                  </li>
                  <li>
                    <a
                      href="https://cal.com/team/manaflow/meeting"
                      target="_blank"
                      rel="noopener noreferrer"
                      className="inline-flex h-8 items-center bg-blue-500 px-3 text-sm font-semibold text-white hover:bg-blue-400"
                    >
                      Book a meeting
                    </a>
                  </li>
                </ul>
              </nav>
            </div>
          </div>
        </div>
      </header>

      <section className="pt-10 pb-8">
        <div className="container max-w-5xl mx-auto px-3 sm:px-5">
          <div className="grid grid-cols-[4px_1fr] gap-6">
            <div className="bg-blue-500 rounded-sm" aria-hidden="true"></div>
            <div>
              <h1 className="text-4xl sm:text-4xl md:text-4xl font-semibold mb-6">
                Orchestrate AI coding agents in parallel
              </h1>

              <p className="text-lg text-neutral-600 dark:text-neutral-300 mb-4 leading-relaxed">
                cmux spawns Claude Code, Codex, Gemini CLI, Amp, Opencode, and
                other coding agent CLIs in parallel across multiple tasks. For
                each run, cmux spawns an isolated VS Code instance via Docker
                with the git diff UI and terminal.
              </p>
              <p className="text-lg text-neutral-300 leading-relaxed">
                Learn more about the{" "}
                <a
                  href="#about"
                  className="text-sky-400 hover:text-sky-300 underline decoration-dotted underline-offset-4"
                >
                  {" "}
                  vision
                </a>
                ,{" "}
                <a
                  href="#features"
                  className="text-sky-400 hover:text-sky-300 underline decoration-dotted underline-offset-4"
                >
                  how it works
                </a>
                , or see the{" "}
                <a
                  href="#roadmap"
                  className="text-sky-400 hover:text-sky-300 underline decoration-dotted underline-offset-4"
                >
                  roadmap
                </a>
                .
              </p>

              <div className="mt-10 flex flex-col sm:flex-row items-center gap-4">
                <a
                  href="https://github.com/manaflow-ai/cmux"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-flex items-center gap-2 px-6 py-3 bg-white text-black hover:bg-neutral-200 rounded-lg font-medium transition-colors"
                >
                  <ClientIcon
                    icon={Github}
                    className="h-5 w-5"
                    aria-hidden="true"
                  />
                  <span>View on GitHub</span>
                </a>
                <div className="bg-neutral-900 border border-neutral-800 rounded-lg px-4 py-3 font-mono text-sm flex items-center gap-3">
                  <span className="text-white">$ bunx cmux</span>
                  <button
                    onClick={() => copyToClipboard("bunx cmux")}
                    className="text-neutral-500 hover:text-white transition-colors"
                  >
                    {copiedCommand === "bunx cmux" ? (
                      <ClientIcon
                        icon={Check}
                        className="h-4 w-4 text-green-400"
                        aria-hidden="true"
                      />
                    ) : (
                      <ClientIcon
                        icon={Copy}
                        className="h-4 w-4"
                        aria-hidden="true"
                      />
                    )}
                  </button>
                </div>
                <div className="bg-neutral-900 border border-neutral-800 rounded-lg px-4 py-3 font-mono text-sm flex items-center gap-3">
                  <span className="text-white">$ npx cmux</span>
                  <button
                    onClick={() => copyToClipboard("npx cmux")}
                    className="text-neutral-500 hover:text-white transition-colors"
                  >
                    {copiedCommand === "npx cmux" ? (
                      <ClientIcon
                        icon={Check}
                        className="h-4 w-4 text-green-400"
                        aria-hidden="true"
                      />
                    ) : (
                      <ClientIcon
                        icon={Copy}
                        className="h-4 w-4"
                        aria-hidden="true"
                      />
                    )}
                  </button>
                </div>
              </div>
            </div>
          </div>
          {/* First demo image combined with hero */}
          <div className="mt-16 mb-8 relative overflow-hidden rounded-lg">
            <Image
              src="/cmux-demo-2.png"
              alt="cmux dashboard showing parallel AI agent execution"
              width={1200}
              height={800}
              className="w-full h-auto"
              priority
            />
          </div>
          <div className="flex justify-center">
            <div className="w-48 h-px bg-neutral-200 dark:bg-neutral-800"></div>
          </div>
        </div>
      </section>

      <section id="about" className="pt-8 px-4 sm:px-6 lg:px-12">
        <div className="container max-w-5xl mx-auto">
          <h2 className="text-2xl font-semibold text-center mb-8">
            Rethinking the developer interface
          </h2>

          <div className="space-y-8 text-neutral-400 mb-12">
            <div className="space-y-2">
              <p>
                <span className="text-white font-semibold">
                  The interface is the bottleneck.
                </span>{" "}
                We've spent years making AI agents better at coding, but almost
                no time making it easier to verify their work. The result?
                Developers spend 80% of their time reviewing and 20% prompting.
              </p>
              <blockquote className="border-l-2 border-neutral-800 pl-4 text-neutral-300">
                <p>
                  Running multiple agents at once sounds powerful until it turns
                  into chaos: 3-4 terminals, each on a different task, and
                  you're asking, “Which one is on auth? Did the database
                  refactor finish?” You end up bouncing between windows, running
                  git diff, and piecing together what changed where.
                </p>
              </blockquote>
            </div>
            <div className="space-y-2">
              <p>
                <span className="text-white font-semibold">
                  Isolation enables scale.
                </span>{" "}
                When each agent runs in its own container with its own VS Code
                instance, you eliminate the confusion of shared state. Every
                diff is clean. Every terminal output is separate. Every
                verification is independent.
              </p>
              <blockquote className="border-l-2 border-neutral-800 pl-4 text-neutral-300">
                <p>
                  The issue isn't that agents aren't good — they're getting
                  scary good. It's that our tools were designed for a different
                  era. VS Code was built for writing code, not reviewing five
                  parallel streams of AI-generated changes. Terminals expect
                  sequential commands, not a fleet of autonomous workers.
                </p>
              </blockquote>
            </div>
            <div className="space-y-2">
              <p>
                <span className="text-white font-semibold">
                  Verification is non-negotiable.
                </span>{" "}
                Code diffs are just the start. We need to see the running
                application, the test results, the performance metrics—all in
                real-time, for every agent, without switching contexts.
              </p>
              <blockquote className="border-l-2 border-neutral-800 pl-4 text-neutral-300">
                <p>
                  cmux solves this by giving each agent its own world: separate
                  Docker container, separate VS Code, separate git state. VS
                  Code opens with the git diff already showing. Every change is
                  isolated to its task, so you can see exactly what each agent
                  did — immediately — without losing context. That's what makes
                  running 10+ agents actually workable.
                </p>
              </blockquote>
            </div>
          </div>
        </div>
      </section>

      <div className="flex justify-center py-8">
        <div className="w-48 h-px bg-neutral-200 dark:bg-neutral-800"></div>
      </div>

      <section id="features" className="pt-8 px-4 sm:px-6 lg:px-12">
        <div className="container max-w-5xl mx-auto">
          <h2 className="text-2xl font-semibold mb-8 text-center">
            How cmux works today
          </h2>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div className="space-y-6">
              <div>
                <h3 className="font-semibold mb-2 flex items-center gap-2">
                  <ClientIcon
                    icon={GitBranch}
                    className="h-4 w-4 text-neutral-500"
                    aria-hidden="true"
                  />
                  Separate VS Code IDE instances
                </h3>
                <p className="text-sm text-neutral-400">
                  Each agent runs in its own VS Code instance. You can open them
                  in your IDE of choice, locally or remotely.
                </p>
              </div>

              <div>
                <h3 className="font-semibold mb-2 flex items-center gap-2">
                  <ClientIcon
                    icon={Users}
                    className="h-4 w-4 text-neutral-500"
                    aria-hidden="true"
                  />
                  Multiple agent support
                </h3>
                <p className="text-sm text-neutral-400">
                  Claude Code, Codex, Gemini CLI, Amp, Opencode, and other
                  coding agent CLIs. Particularly useful to run agents together
                  and find the best one for the task.
                </p>
              </div>

              <div>
                <h3 className="font-semibold mb-2 flex items-center gap-2">
                  <ClientIcon
                    icon={Star}
                    className="h-4 w-4 text-neutral-500"
                    aria-hidden="true"
                  />
                  Git extension UI
                </h3>
                <p className="text-sm text-neutral-400">
                  On mount, VS Code opens the git extension's diff UI. Review
                  changes without context switching.
                </p>
              </div>
            </div>

            <div className="space-y-6">
              <div>
                <h3 className="font-semibold mb-2 flex items-center gap-2">
                  <ClientIcon
                    icon={Cloud}
                    className="h-4 w-4 text-neutral-500"
                    aria-hidden="true"
                  />
                  Sandbox environment preview
                </h3>
                <p className="text-sm text-neutral-400">
                  Spin up isolated sandboxes to preview your changes safely.
                  cmux uses fast cloud sandboxes or Docker locally.
                </p>
              </div>

              <div>
                <h3 className="font-semibold mb-2 flex items-center gap-2">
                  <ClientIcon
                    icon={GitPullRequest}
                    className="h-4 w-4 text-neutral-500"
                    aria-hidden="true"
                  />
                  Code review page
                </h3>
                <p className="text-sm text-neutral-400">
                  Central place to review changes across agents. View diffs for
                  draft PRs and committed work without leaving the dashboard.
                </p>
              </div>

              <div>
                <h3 className="font-semibold mb-2 flex items-center gap-2">
                  <ClientIcon
                    icon={Zap}
                    className="h-4 w-4 text-neutral-500"
                    aria-hidden="true"
                  />
                  Task management
                </h3>
                <p className="text-sm text-neutral-400">
                  Track parallel executions, view task history, keep containers
                  alive when needed.
                </p>
              </div>
            </div>
          </div>
          <div className="mt-8 relative overflow-hidden rounded-lg">
            <Image
              src="/cmux-demo-3.png"
              alt="cmux verification view highlighting git changes and previews"
              width={1200}
              height={800}
              className="w-full h-auto"
              loading="lazy"
            />
          </div>
        </div>
      </section>

      <div className="flex justify-center py-8">
        <div className="w-48 h-px bg-neutral-200 dark:bg-neutral-800"></div>
      </div>

      <section id="roadmap" className="pt-8 pb-8 px-4 sm:px-6 lg:px-12">
        <div className="container max-w-5xl mx-auto">
          <h2 className="text-2xl font-semibold mb-8 text-center">
            The roadmap
          </h2>
          <div className="space-y-6">
            <div className="text-neutral-400">
              <p className="mb-6">
                We're building the missing layer between AI agents and
                developers. Not another agent, not another IDE—but the
                verification interface that makes managing 10, 20, or 100
                parallel agents as easy as managing one.
              </p>
            </div>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div className="bg-neutral-900/50 border border-neutral-800 rounded-lg p-6">
                <h3 className="font-semibold mb-3 text-lg">
                  Verification at scale
                </h3>
                <p className="text-sm text-neutral-400 mb-4">
                  Every code change will have a visual preview. Backend API
                  changes show request/response diffs. Frontend changes show
                  before/after screenshots. Database migrations show schema
                  changes visually.
                </p>
              </div>
              <div className="bg-neutral-900/50 border border-neutral-800 rounded-lg p-6">
                <h3 className="font-semibold mb-3 text-lg">
                  Intelligent task routing
                </h3>
                <p className="text-sm text-neutral-400 mb-4">
                  Automatically route tasks to the best agent based on
                  performance history. Claude for complex refactors, Codex for
                  test generation, specialized models for documentation.
                </p>
              </div>
              <div className="bg-neutral-900/50 border border-neutral-800 rounded-lg p-6">
                <h3 className="font-semibold mb-3 text-lg">
                  Verification workflows
                </h3>
                <p className="text-sm text-neutral-400 mb-4">
                  Define verification criteria upfront. Set test coverage
                  requirements, performance benchmarks, security checks. Agents
                  can't mark tasks complete until verification passes.
                </p>
              </div>
              <div className="bg-neutral-900/50 border border-neutral-800 rounded-lg p-6">
                <h3 className="font-semibold mb-3 text-lg">
                  Cross-agent coordination
                </h3>
                <p className="text-sm text-neutral-400 mb-4">
                  Agents will communicate through a shared context layer. One
                  agent's output becomes another's input. Automatic conflict
                  resolution when agents modify the same files.
                </p>
              </div>
            </div>
            <div className="mt-8 p-6 bg-neutral-900/60 border border-neutral-800 rounded-lg">
              <h3 className="font-semibold mb-3">
                The endgame: Autonomous verification
              </h3>
              <p className="text-sm text-neutral-400">
                Eventually, verification itself will be automated. A manager
                agent will review the work of worker agents, using the same
                interfaces you use today. It will approve simple changes,
                escalate complex ones, and learn from your verification
                patterns. The goal isn't to replace developers—it's to amplify
                them 100x by removing the verification bottleneck entirely.
              </p>
            </div>
          </div>
        </div>
      </section>

      <div className="flex justify-center py-8">
        <div className="w-48 h-px bg-neutral-200 dark:bg-neutral-800"></div>
      </div>

      <section id="requirements" className="py-8 px-4 sm:px-6 lg:px-12">
        <div className="container max-w-5xl mx-auto text-center">
          <h2 className="text-2xl font-semibold mb-4">Requirements</h2>
          <p className="text-neutral-400 mb-8">
            cmux runs locally on your machine. You'll need:
          </p>
          <div className="flex flex-col sm:flex-row gap-4 justify-center text-sm">
            <div className="bg-neutral-900 border border-neutral-800 rounded-lg px-6 py-3">
              Docker installed
            </div>
            <div className="bg-neutral-900 border border-neutral-800 rounded-lg px-6 py-3">
              Node.js 20+ or Bun 1.1.25+
            </div>
            <div className="bg-neutral-900 border border-neutral-800 rounded-lg px-6 py-3">
              macOS or Linux
            </div>
          </div>
        </div>
      </section>

      <div className="flex justify-center py-8">
        <div className="w-48 h-px bg-neutral-200 dark:bg-neutral-800"></div>
      </div>

      <footer className="py-8 px-4 sm:px-6 lg:px-12">
        <div className="container max-w-5xl mx-auto flex flex-col sm:flex-row justify-between items-center gap-4">
          <div className="flex items-center gap-2">
            <ClientIcon
              icon={Terminal}
              className="h-4 w-4 text-neutral-500"
              aria-hidden="true"
            />
            <span className="text-sm text-neutral-500 font-mono">
              cmux by manaflow
            </span>
          </div>
          <div className="flex items-center gap-6 text-sm text-neutral-500">
            <a
              href="https://github.com/manaflow-ai/cmux"
              className="hover:text-white transition-colors"
            >
              GitHub
            </a>
            <a
              href="https://twitter.com/manaflowai"
              className="hover:text-white transition-colors"
            >
              Twitter
            </a>
            <a
              href="https://discord.gg/7VY58tftMg"
              className="hover:text-white transition-colors"
            >
              Discord
            </a>
          </div>
        </div>
      </footer>
    </div>
  );
}
