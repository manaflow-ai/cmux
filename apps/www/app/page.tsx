import { MacDownloadLink } from "@/components/mac-download-link";
import { SiteHeader } from "@/components/site-header";
import {
  ArrowRight,
  Cloud,
  GitPullRequest,
  Layers,
  Settings,
  Terminal,
  Users,
  Zap,
} from "lucide-react";
import Image from "next/image";
import Link from "next/link";
import cmuxDemo0 from "@/docs/assets/cmux0.png";
import cmuxDemo1 from "@/docs/assets/cmux1.png";
import cmuxDemo2 from "@/docs/assets/cmux2.png";
import cmuxDemo3 from "@/docs/assets/cmux3.png";
import { fetchLatestRelease } from "@/lib/fetch-latest-release";
import { fetchGithubRepoStats } from "@/lib/fetch-github-stars";

const heroHighlights = [
  {
    title: "Run multiple agent CLIs side-by-side",
    description: "Claude Code, Codex, Gemini CLI, Amp, Opencode, and more on the same task.",
  },
  {
    title: "Dedicated VS Code instance per agent",
    description: "Each task launches an isolated VS Code, terminal, and git diff view ready to inspect.",
  },
  {
    title: "Preview environments for quick verification",
    description: "Tasks launches browser previews so you can verify that the code works on dev server.",
  },
];

const productPillars = [
  {
    title: "Isolated VS Code IDE instances",
    description:
      "Each agent runs in its own VS Code instance so you can context switch between different tasks with the click of a button.",
    icon: Layers,
  },
  {
    title: "Multiple agent support",
    description:
      "Run multiple Claude Code, Codex, Gemini CLI, Amp, Opencode, and other coding agent CLIs in parallel on the same or separate tasks.",
    icon: Users,
  },
  {
    title: "Fast git code diff viewer",
    description:
      "Every agent includes a git code diff viewer so you can review their code changes, tests & checks, and close or merge on the same page.",
    icon: GitPullRequest,
  },
  {
    title: "Dev server preview environments",
    description:
      "Each agent spins up isolated cloud sandbox environments to preview your dev servers on its on browser so you can verify tasks directly.",
    icon: Zap,
  },
  {
    title: "Supports cloud sandboxes or local Docker",
    description:
      "cmux includes configurations for cloud sandbox mode with repos, cloud sandbox mode with environments, and local mode with Docker containers.",
    icon: Cloud,
  },
  {
    title: "Integrates with your local auth setup",
    description:
      "cmux integrates with your local auth setup and you can bring your OpenAI and Claude subscriptions or API keys to run the coding agents on tasks.",
    icon: Zap,
  },
];

const workflowSteps = [
  {
    id: "step-workspaces",
    title: "1. Configure run context",
    copy:
      "Set up the repo or environment for your task, configure scripts, and pick the agents you want to run.",
    checklist: [
      "Configure dev and maintenance scripts on the Environments page or link the repo you need.",
      "Select the branches that apply to the task before launching agents.",
      "Choose which agents should execute in parallel for the run.",
    ],
  },
  {
    id: "step-agents",
    title: "2. Watch agents execute",
    copy:
      "Follow each agent's VS Code instance as they work; completion shows a green check and the crown evaluator picks the best run.",
    checklist: [
      "Monitor the dedicated VS Code sessions to see agents progress in real time.",
      "Wait for every task card to reach the green check before moving ahead.",
      "Review the crown evaluator's selection once all agents finish.",
    ],
  },
  {
    id: "step-review",
    title: "3. Verify diffs and previews",
    copy:
      "Open the diff viewer, confirm tests, and use the auto-started preview environments to validate changes.",
    checklist: [
      "Inspect code updates in the git diff viewer for each agent.",
      "Review test and command output captured during the run.",
      "Launch the preview environment dev servers to confirm everything works.",
    ],
  },
  {
    id: "step-ship",
    title: "4. Ship directly from cmux",
    copy:
      "Create your pull request inside cmux and finish the merge once verification is done.",
    checklist: [
      "Open a pull request from the cmux review surface when you're ready.",
      "Attach verification notes and confirm required checks before finishing.",
      "Merge the pull request in cmux to wrap the run.",
    ],
  },
];

const verificationHighlights = [
  {
    title: "Diff viewer for each agent's changes",
    paragraphs: [
      "Review every commit-ready change in a focused diff viewer that scopes to the agents working the task.",
      "Filter by agent, jump between files, and confirm checks without leaving the review surface.",
    ],
    asset: cmuxDemo3,
  },
  {
    title: "Isolated VS Code workspaces per agent",
    paragraphs: [
      "Each agent operates in a clean VS Code window with terminals, command history, and context tailored to its run.",
      "Toggle between windows instantly to compare approaches and keep an eye on automated progress.",
    ],
    asset: cmuxDemo1,
  },
  {
    title: "Preview dev server environments directly",
    paragraphs: [
      "cmux spins up the right dev servers based on your environment configuration as soon as work starts.",
      "Open the live preview to validate UI, APIs, and workflows manually before you publish the pull request.",
    ],
    asset: cmuxDemo2,
  },
];

export default async function LandingPage() {
  const [{ fallbackUrl, latestVersion, macDownloadUrls }, githubRepo] =
    await Promise.all([fetchLatestRelease(), fetchGithubRepoStats()]);

  return (
    <div className="relative flex min-h-dvh flex-col bg-[#030712] text-foreground">
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 -z-10 overflow-hidden"
      >
        <div className="absolute inset-x-[-20%] top-[-30%] h-[40rem] rounded-full bg-gradient-to-br from-red-500/30 via-orange-500/25 to-yellow-500/20 blur-3xl" />
        <div className="absolute inset-x-[20%] top-[-10%] h-[35rem] rounded-full bg-gradient-to-br from-yellow-400/25 via-green-400/20 to-emerald-500/15 blur-[160px]" />
        <div className="absolute inset-x-[30%] top-[20%] h-[30rem] rounded-full bg-gradient-to-br from-cyan-400/20 via-blue-500/20 to-indigo-500/15 blur-[160px]" />
        <div className="absolute inset-x-[10%] bottom-[-20%] h-[32rem] rounded-full bg-gradient-to-tr from-indigo-600/25 via-purple-600/20 to-pink-500/15 blur-[200px]" />
      </div>

      <SiteHeader
        fallbackUrl={fallbackUrl}
        latestVersion={latestVersion}
        macDownloadUrls={macDownloadUrls}
        githubStars={githubRepo.stars}
        githubUrl={githubRepo.url}
      />

      <main className="relative z-10 flex-1">
        <section className="mx-auto max-w-6xl px-4 pb-16 pt-16 sm:px-6 sm:pb-24 sm:pt-12">
          <div className="grid gap-10 lg:grid-cols-[1.1fr_0.9fr] lg:items-center">
            <div className="space-y-8">

              <div className="space-y-6">
                <h1 className="text-4xl font-semibold tracking-tight text-white sm:text-5xl">
                  Universal AI coding agent manager for 10x engineers
                </h1>
                <div className="space-y-4 text-base text-neutral-300 sm:text-lg">
                  <p>
                    cmux is a universal AI coding agent manager that supports Claude Code, Codex, Gemini CLI, Amp, Opencode, and other coding CLIs.
                  </p>
                  <p>
                    Every run spins up an isolated VS Code workspace either in the cloud or in a local Docker container with the git diff view, terminal, and dev server preview ready so parallel agent work stays verifiable, fast, and ready to ship.
                  </p>
                  <p className="text-sm text-neutral-400 sm:text-base">
                    Learn more about the
                    {" "}
                    <a
                      className="text-sky-400 hover:text-sky-300 underline decoration-dotted underline-offset-4"
                      href="#nav-about"
                    >
                      vision
                    </a>
                    ,
                    {" "}
                    <a
                      className="text-sky-400 hover:text-sky-300 underline decoration-dotted underline-offset-4"
                      href="#nav-features"
                    >
                      how it works today
                    </a>
                    , or explore the
                    {" "}
                    <a
                      className="text-sky-400 hover:text-sky-300 underline decoration-dotted underline-offset-4"
                      href="#nav-roadmap"
                    >
                      roadmap
                    </a>
                    .
                  </p>
                </div>
              </div>
              <div className="flex flex-col gap-3 sm:flex-row">
                <MacDownloadLink
                  autoDetect
                  fallbackUrl={fallbackUrl}
                  className="inline-flex items-center justify-center gap-2 rounded-lg border border-white/20 bg-white px-4 py-3 text-sm font-semibold text-black shadow-xl transition hover:bg-neutral-100"
                  title={
                    latestVersion
                      ? `Download cmux ${latestVersion} for macOS`
                      : "Download cmux for macOS"
                  }
                  urls={macDownloadUrls}
                >
                  <span className="flex items-center gap-2">
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      viewBox="0 0 16 16"
                      fill="currentColor"
                      className="h-4 w-4"
                    >
                      <path d="M12.665 15.358c-.905.844-1.893.711-2.843.311-1.006-.409-1.93-.427-2.991 0-1.33.551-2.03.391-2.825-.31C-.498 10.886.166 4.078 5.28 3.83c1.246.062 2.114.657 2.843.71 1.09-.213 2.133-.826 3.296-.746 1.393.107 2.446.64 3.138 1.6-2.88 1.662-2.197 5.315.443 6.337-.526 1.333-1.21 2.657-2.345 3.635zM8.03 3.778C7.892 1.794 9.563.16 11.483 0c.268 2.293-2.16 4-3.452 3.777" />
                    </svg>
                    <span>Download for macOS</span>
                  </span>
                </MacDownloadLink>
                <Link
                  className="inline-flex items-center justify-center gap-2 rounded-lg border border-white/10 bg-white/5 px-4 py-3 text-sm font-semibold text-white transition hover:border-white/30 hover:bg-white/10"
                  href="https://github.com/manaflow-ai/cmux"
                >
                  See GitHub repo
                  <svg
                    className="h-4 w-4"
                    aria-hidden
                    fill="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
                  </svg>
                </Link>
              </div>
              {latestVersion ? (
                <p className="text-xs text-neutral-400">
                  Latest release: cmux {latestVersion}. Need another build? Visit the GitHub release page for all downloads.
                </p>
              ) : (
                <p className="text-xs text-neutral-400">
                  Having trouble with the macOS download? Use the fallback build on our release page.
                </p>
              )}
            </div>
            <div className="relative">
              <div className="rounded-3xl border border-white/10 bg-white/5 p-6 shadow-[0_40px_120px_-40px_rgba(56,189,248,0.35)] backdrop-blur lg:ml-auto lg:max-w-lg">
                <div className="space-y-6">
                  <div className="relative aspect-video overflow-hidden rounded-xl">
                    <iframe
                      className="h-full w-full"
                      src="https://www.youtube.com/embed/YtQTKSM_wsA"
                      title="cmux demo video"
                      allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
                      allowFullScreen
                    />
                  </div>
                  {heroHighlights.map((highlight) => (
                    <div key={highlight.title} className="flex gap-4">
                      <div className="mt-0.5 h-8 w-8 flex-none rounded-full bg-gradient-to-br from-sky-500/80 to-indigo-500/80 text-center text-base font-semibold leading-8 text-white shadow-lg">
                        •
                      </div>
                      <div className="space-y-1">
                        <h3 className="text-sm font-semibold text-white">
                          {highlight.title}
                        </h3>
                        <p className="text-sm text-neutral-300">{highlight.description}</p>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </div>
          <div className="mt-12 relative overflow-hidden rounded-2xl">
            <Image
              src={cmuxDemo0}
              alt="cmux dashboard showing parallel AI agents"
              width={3248}
              height={2112}
              sizes="(min-width: 1024px) 1024px, 100vw"
              quality={100}
              className="h-full w-full object-cover"
              priority
            />
          </div>
        </section>

        <section id="nav-about" className="mx-auto max-w-6xl px-4 pb-20 sm:px-6 scroll-mt-32">
          <div className="space-y-12">
            <div className="space-y-3 text-center">
              <h2 className="text-2xl font-semibold text-white sm:text-3xl">
                Rethinking the developer interface
              </h2>
              <p className="mx-auto max-w-3xl text-sm text-neutral-400 sm:text-base">
                Everyone is focusing on making AI agents better at coding but not on making it easier to verify their work. cmux focuses on the verification surface so developers who use multiple agents can ship fast and accurate code.
              </p>
            </div>
            <div className="space-y-8 text-sm text-neutral-300 sm:text-base">
              <div className="space-y-2">
                <p>
                  <span className="text-white font-semibold">The interface is the bottleneck.</span>{" "}
                  Developers still spend most of their time reviewing and verifying code instead of prompting. cmux removes the window-juggling and diff spelunking that slows teams down.
                </p>
                <blockquote className="border-l-2 border-white/10 pl-4 text-neutral-400">
                  <p>
                    Running multiple agents at once sounds powerful until it turns into chaos: three or four terminals, each on a different task, and you&apos;re asking, &ldquo;Which one is on auth? Did the database refactor finish?&rdquo;
                  </p>
                </blockquote>
              </div>
              <div className="space-y-2">
                <p>
                  <span className="text-white font-semibold">Isolation enables scale.</span>{" "}
                  Each agent runs in its own container with its own VS Code instance. Every diff is clean, every terminal output is separate, and every verification stays independent.
                </p>
                <blockquote className="border-l-2 border-white/10 pl-4 text-neutral-400">
                  <p>
                    The issue isn&apos;t that agents aren&apos;t good—they&apos;re getting scary good. It&apos;s that our tools were built for a single developer, not for reviewing five parallel streams of AI-generated changes.
                  </p>
                </blockquote>
              </div>
              <div className="space-y-2">
                <p>
                  <span className="text-white font-semibold">Verification is non-negotiable.</span>{" "}
                  Code diffs are just the start. We need to see running apps, test results, and metrics for every agent without losing context. cmux keeps that verification front and center.
                </p>
                <blockquote className="border-l-2 border-white/10 pl-4 text-neutral-400">
                  <p>
                    cmux gives each agent its own world: separate container in the cloud or Docker, separate VS Code, separate git state. You can see exactly what changed immediately—without losing context.
                  </p>
                </blockquote>
              </div>
            </div>
            <div className="mt-12 relative overflow-hidden rounded-2xl">
              <Image
                src={cmuxDemo1}
                alt="cmux dashboard showing task management for AI agents"
                width={3248}
                height={2112}
                sizes="(min-width: 1024px) 1024px, 100vw"
                quality={100}
                className="h-full w-full object-cover"
                priority
              />
            </div>
          </div>
        </section>

        <section id="nav-features" className="mx-auto max-w-6xl px-4 pb-20 sm:px-6 scroll-mt-32">
          <div className="space-y-12">
            <div className="space-y-3 text-center">
              <h2 className="text-2xl font-semibold text-white sm:text-3xl">
                How cmux works today
              </h2>
              <p className="mx-auto max-w-3xl text-sm text-neutral-400 sm:text-base">
                The cmux dashboard keeps every agent and workspace organized so you can launch, monitor, and review without alt-tabbing between terminals, keeping track of VS Code windows, and restarting dev servers.
              </p>
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              {productPillars.map(({ icon: Icon, title, description }) => (
                <div
                  key={title}
                  className="group relative overflow-hidden rounded-2xl border border-white/10 bg-white/5 p-6 transition hover:border-white/20 hover:bg-white/10"
                >
                  <div className="flex items-start gap-4">
                    <div className="rounded-xl bg-gradient-to-br from-sky-500/40 via-blue-500/40 to-purple-500/40 p-3 text-white shadow-lg">
                      <Icon className="h-5 w-5" aria-hidden />
                    </div>
                    <div className="space-y-2">
                      <h3 className="text-base font-semibold text-white">{title}</h3>
                      <p className="text-sm text-neutral-300">{description}</p>
                    </div>
                  </div>
                </div>
              ))}
            </div>
            <div className="mt-10 relative overflow-hidden rounded-2xl">
              <Image
                src={cmuxDemo2}
                alt="cmux vscode instances showing diffs"
                width={3248}
                height={2112}
                sizes="(min-width: 1024px) 1024px, 100vw"
                quality={100}
                className="h-full w-full object-cover"
                loading="lazy"
              />
            </div>
          </div>
        </section>

        <section id="nav-workflow" className="mx-auto max-w-6xl px-4 pb-20 sm:px-6 scroll-mt-32">
          <div className="flex flex-col gap-16 lg:flex-row">
            <div className="lg:w-1/3">
              <h2 className="text-2xl font-semibold text-white sm:text-3xl">
                A guided workflow from start to finish
              </h2>
              <p className="mt-4 text-sm text-neutral-400 sm:text-base">
                Each phase inside cmux is integral to keep the process fast and confidence high while coding agents execute tasks in parallel.
              </p>
            </div>
            <div className="grid flex-1 gap-6 sm:grid-cols-2">
              {workflowSteps.map((step, index) => (
                <article
                  key={step.id}
                  className="flex flex-col justify-between rounded-2xl border border-white/10 bg-neutral-950/80 p-6 shadow-[inset_0_1px_0_rgba(255,255,255,0.05)]"
                >
                  <div className="space-y-4">
                    <span className="inline-flex h-9 w-9 items-center justify-center rounded-full border border-white/10 bg-white/10 text-sm font-semibold text-white">
                      {index + 1}
                    </span>
                    <div className="space-y-2">
                      <h3 className="text-base font-semibold text-white">{step.title}</h3>
                      <p className="text-sm text-neutral-300">{step.copy}</p>
                    </div>
                    <ul className="space-y-2 text-xs text-neutral-400">
                      {step.checklist.map((item) => (
                        <li
                          key={item}
                          className="flex items-center gap-2 rounded-lg border border-dashed border-white/10 bg-white/5 px-3 py-2"
                        >
                          <Settings className="h-3.5 w-3.5 flex-none text-sky-300" aria-hidden />
                          <span>{item}</span>
                        </li>
                      ))}
                    </ul>
                  </div>
                </article>
              ))}
            </div>
          </div>
        </section>

        <section id="nav-verification" className="mx-auto max-w-6xl px-4 pb-20 sm:px-6 scroll-mt-32">
          <div className="space-y-10">
            <div className="space-y-3 text-center">
              <h2 className="text-2xl font-semibold text-white sm:text-3xl">
                Verification views that make scale trustworthy
              </h2>
              <p className="mx-auto max-w-3xl text-sm text-neutral-400 sm:text-base">
                Diff viewers, dedicated VS Code workspaces, and live preview dev server environments keep human software engineers in the loop.
              </p>
            </div>
            <div className="grid gap-10">
              {verificationHighlights.map((highlight, index) => (
                <div
                  key={highlight.title}
                  className="grid gap-8 lg:grid-cols-2 lg:items-center"
                >
                  <div className={`space-y-4 ${index % 2 === 1 ? "lg:order-2" : ""}`}>
                    <h3 className="text-xl font-semibold text-white">{highlight.title}</h3>
                    <div className="space-y-3 text-sm text-neutral-300">
                      {highlight.paragraphs.map((paragraph, paragraphIndex) => (
                        <p key={`${highlight.title}-${paragraphIndex}`}>{paragraph}</p>
                      ))}
                    </div>
                  </div>
                  <div className={index % 2 === 1 ? "lg:order-1" : ""}>
                    <Image
                      alt={highlight.title}
                      className="h-full w-full rounded-2xl object-cover"
                      height={2112}
                      priority={index === 0}
                      quality={100}
                      sizes="(min-width: 1024px) 640px, 100vw"
                      src={highlight.asset}
                      width={3248}
                    />
                  </div>
                </div>
              ))}
            </div>
          </div>
        </section>

        <section id="nav-requirements" className="mx-auto max-w-4xl px-4 pb-20 text-center sm:px-6 scroll-mt-32">
          <h2 className="text-2xl font-semibold text-white sm:text-3xl">Requirements</h2>
          <p className="mt-4 text-sm text-neutral-400 sm:text-base">
            cmux runs locally on your machine. You&apos;ll need:
          </p>
          <div className="mt-8 flex flex-col items-center justify-center gap-4 sm:flex-row">
            <div className="w-full rounded-xl border border-white/10 bg-white/5 px-6 py-4 text-sm text-white sm:w-auto text-center">
              Docker installed or use cmux cloud
            </div>
            <div className="w-full rounded-xl border border-white/10 bg-white/5 px-6 py-4 text-sm text-white sm:w-auto text-center">
              macOS 13+, Linux (preview), Windows (waitlist)
            </div>
          </div>
        </section>

        <section id="nav-contact" className="mx-auto max-w-5xl px-4 pb-24 sm:px-6 scroll-mt-32">
          <div className="flex flex-col gap-6 rounded-3xl border border-white/10 bg-white/5 p-8 sm:flex-row sm:items-center sm:justify-between">
            <div className="space-y-3">
              <h2 className="text-xl font-semibold text-white sm:text-2xl">Talk to the team</h2>
              <p className="text-sm text-neutral-300 sm:text-base">
                Curious how cmux can power your workflow? Book time with us for a demo or deep dive.
              </p>
            </div>
            <div className="flex flex-col gap-3 sm:flex-row">
              <a
                className="inline-flex items-center justify-center gap-2 rounded-lg border border-white/10 bg-white/5 px-4 py-3 text-sm font-semibold text-white transition hover:border-white/30 hover:bg-white/10"
                href="https://cal.com/team/manaflow/meeting"
                rel="noopener noreferrer"
                target="_blank"
              >
                Book meeting
                <ArrowRight className="h-4 w-4" aria-hidden />
              </a>
              {/* <Link
                className="inline-flex items-center justify-center gap-2 rounded-lg border border-white/10 bg-white/5 px-4 py-3 text-sm font-semibold text-white transition hover:border-white/30 hover:bg-white/10"
                href="/tutorial"
              >
                Browse tutorial
                <ArrowRight className="h-4 w-4" aria-hidden />
              </Link> */}
            </div>
          </div>
        </section>
      </main>

      <footer className="border-t border-white/10 bg-black/50">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-6 px-4 py-8 text-sm text-neutral-500 sm:flex-row sm:px-6">
          <div className="flex items-center gap-2">
            <Terminal className="h-4 w-4 text-neutral-600" aria-hidden />
            <span className="font-mono">cmux by manaflow</span>
          </div>
          <div className="flex items-center gap-6">
            {/* <a className="transition hover:text-white" href="/tutorial">
              Tutorial
            </a> */}
            <a
              className="transition hover:text-white"
              href="https://github.com/manaflow-ai/cmux"
              rel="noopener noreferrer"
              target="_blank"
            >
              GitHub
            </a>
            <a
              className="transition hover:text-white"
              href="https://twitter.com/manaflowai"
              rel="noopener noreferrer"
              target="_blank"
            >
              Twitter
            </a>
            <a
              className="transition hover:text-white"
              href="https://discord.gg/SDbQmzQhRK"
              rel="noopener noreferrer"
              target="_blank"
            >
              Discord
            </a>
          </div>
        </div>
      </footer>
    </div>
  );
}
