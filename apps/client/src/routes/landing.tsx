import { createFileRoute, Link } from '@tanstack/react-router'
import { Button } from '../components/ui/button'
import { ArrowRight, Terminal, GitBranch, Star, Copy, Check, ExternalLink, Github } from 'lucide-react'
import { useState } from 'react'

export const Route = createFileRoute('/landing')({
  component: LandingPage,
})

function LandingPage() {
  const [copiedCommand, setCopiedCommand] = useState<string | null>(null)

  const copyToClipboard = (text: string) => {
    navigator.clipboard.writeText(text)
    setCopiedCommand(text)
    setTimeout(() => setCopiedCommand(null), 2000)
  }

  return (
    <div className="min-h-screen bg-black text-white overflow-y-auto">
      {/* Navigation */}
      <nav className="sticky top-0 w-full z-50 bg-black/90 backdrop-blur-sm border-b border-neutral-900">
        <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
          <div className="flex justify-between items-center h-14">
            <div className="flex items-center gap-2">
              <Terminal className="h-5 w-5" />
              <span className="text-lg font-mono">cmux</span>
            </div>
            <div className="flex items-center gap-4">
              <a 
                href="https://github.com/manaflow-ai/cmux" 
                target="_blank" 
                rel="noopener noreferrer"
                className="flex items-center gap-2 text-sm text-neutral-400 hover:text-white transition-colors"
              >
                <Github className="h-4 w-4" />
                <span>GitHub</span>
                <Star className="h-3 w-3" />
              </a>
              <Button asChild size="sm" variant="outline" className="border-neutral-800 text-white hover:bg-neutral-900">
                <Link to="/dashboard">Sign In</Link>
              </Button>
            </div>
          </div>
        </div>
      </nav>

      {/* Hero Section */}
      <section className="pt-24 pb-16 px-4 sm:px-6 lg:px-8">
        <div className="max-w-4xl mx-auto">
          <h1 className="text-3xl sm:text-4xl font-bold mb-4 font-mono">
            Claude Code manager that spawns Codex/Gemini/OpenCode/Amp in parallel
          </h1>
          
          <p className="text-lg text-neutral-400 mb-8 leading-relaxed">
            cmux spawns Claude Code, Codex, Gemini CLI, Amp, Opencode, and other coding agent CLIs in parallel across multiple tasks. 
            Each run gets an isolated VS Code instance via Docker with the git diff UI and a terminal running your agent.
          </p>

          {/* Quick Install */}
          <div className="flex flex-col sm:flex-row gap-3 mb-12">
            <div className="flex-1 bg-neutral-900 border border-neutral-800 rounded-lg px-4 py-3 font-mono text-sm flex items-center justify-between">
              <span>bunx cmux</span>
              <button
                onClick={() => copyToClipboard('bunx cmux')}
                className="ml-4 text-neutral-500 hover:text-white transition-colors"
              >
                {copiedCommand === 'bunx cmux' ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}
              </button>
            </div>
            <div className="flex-1 bg-neutral-900 border border-neutral-800 rounded-lg px-4 py-3 font-mono text-sm flex items-center justify-between">
              <span>npx cmux</span>
              <button
                onClick={() => copyToClipboard('npx cmux')}
                className="ml-4 text-neutral-500 hover:text-white transition-colors"
              >
                {copiedCommand === 'npx cmux' ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}
              </button>
            </div>
          </div>

          <div className="flex items-center gap-4">
            <Button asChild className="bg-white text-black hover:bg-neutral-200">
              <Link to="/dashboard">
                Try cmux
                <ArrowRight className="ml-2 h-4 w-4" />
              </Link>
            </Button>
            <a 
              href="https://github.com/manaflow-ai/cmux" 
              target="_blank" 
              rel="noopener noreferrer"
              className="inline-flex items-center gap-2 px-4 py-2 rounded-lg border border-neutral-800 hover:bg-neutral-900 transition-colors"
            >
              <Star className="h-4 w-4" />
              Star on GitHub
            </a>
          </div>
        </div>
      </section>

      {/* The Problem */}
      <section className="py-16 px-4 sm:px-6 lg:px-8 border-t border-neutral-900">
        <div className="max-w-4xl mx-auto">
          <h2 className="text-2xl font-bold mb-6">The Problem</h2>
          <div className="space-y-4 text-neutral-400">
            <p>
              If you're like me, you've almost completely moved from Cursor to Claude Code. 
              You spend more time in the terminal + VS Code git extension than in Cursor's sidebar.
            </p>
            <p>
              But you can only juggle four or five Claudes at a time in different parts of the codebase. 
              And you still keep going back to the VS Code UI for diffs.
            </p>
            <p>
              That's why I built cmux — to spawn isolated VS Code instances (making <code className="px-1.5 py-0.5 bg-neutral-900 rounded text-sm">--dangerously-skip-permissions</code> safer!) 
              for every task/coding CLI fanout.
            </p>
          </div>
        </div>
      </section>

      {/* Demo Section */}
      <section className="py-16 px-4 sm:px-6 lg:px-8 border-t border-neutral-900">
        <div className="max-w-4xl mx-auto">
          <h2 className="text-2xl font-bold mb-6">How it works</h2>
          
          <div className="space-y-8">
            {/* Terminal Demo */}
            <div className="bg-neutral-950 border border-neutral-800 rounded-lg overflow-hidden">
              <div className="flex items-center gap-2 px-4 py-2 bg-neutral-900 border-b border-neutral-800">
                <div className="flex gap-1.5">
                  <div className="w-3 h-3 rounded-full bg-red-500"></div>
                  <div className="w-3 h-3 rounded-full bg-yellow-500"></div>
                  <div className="w-3 h-3 rounded-full bg-green-500"></div>
                </div>
                <span className="text-xs text-neutral-500 font-mono ml-2">terminal</span>
              </div>
              <div className="p-4 font-mono text-sm space-y-2">
                <div className="text-neutral-500">$ cmux</div>
                <div className="text-green-400">✓ Starting cmux...</div>
                <div className="text-neutral-400">
                  <br />
                  Select agents to spawn:<br />
                  [x] Claude Code<br />
                  [x] Codex CLI<br />
                  [x] Gemini CLI<br />
                  [ ] Amp<br />
                  [ ] OpenCode<br />
                  <br />
                  Enter task: <span className="text-white">Fix authentication flow and add tests</span><br />
                  <br />
                </div>
                <div className="text-green-400">→ Spawning 3 isolated VS Code instances...</div>
                <div className="text-neutral-500">→ Claude Code: workspace-1 (port 8001)</div>
                <div className="text-neutral-500">→ Codex CLI: workspace-2 (port 8002)</div>
                <div className="text-neutral-500">→ Gemini CLI: workspace-3 (port 8003)</div>
              </div>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div className="bg-neutral-900 border border-neutral-800 rounded-lg p-4">
                <div className="flex items-center gap-2 mb-3">
                  <Terminal className="h-4 w-4 text-green-500" />
                  <span className="text-sm font-mono">Claude Code</span>
                </div>
                <div className="text-xs text-neutral-500 font-mono space-y-1">
                  <div>Analyzing auth flow...</div>
                  <div>Found 3 issues</div>
                  <div>Writing fixes...</div>
                  <div className="text-green-400">✓ Complete</div>
                </div>
              </div>
              <div className="bg-neutral-900 border border-neutral-800 rounded-lg p-4">
                <div className="flex items-center gap-2 mb-3">
                  <Terminal className="h-4 w-4 text-blue-500" />
                  <span className="text-sm font-mono">Codex CLI</span>
                </div>
                <div className="text-xs text-neutral-500 font-mono space-y-1">
                  <div>Reviewing code...</div>
                  <div>Generating tests...</div>
                  <div>Running test suite...</div>
                  <div className="text-yellow-400">→ In progress</div>
                </div>
              </div>
              <div className="bg-neutral-900 border border-neutral-800 rounded-lg p-4">
                <div className="flex items-center gap-2 mb-3">
                  <Terminal className="h-4 w-4 text-purple-500" />
                  <span className="text-sm font-mono">Gemini CLI</span>
                </div>
                <div className="text-xs text-neutral-500 font-mono space-y-1">
                  <div>Checking edge cases...</div>
                  <div>Adding error handling...</div>
                  <div>Updating docs...</div>
                  <div className="text-green-400">✓ Complete</div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Features */}
      <section className="py-16 px-4 sm:px-6 lg:px-8 border-t border-neutral-900">
        <div className="max-w-4xl mx-auto">
          <h2 className="text-2xl font-bold mb-6">Why cmux?</h2>
          
          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div className="space-y-6">
              <div>
                <h3 className="font-semibold mb-2 flex items-center gap-2">
                  <GitBranch className="h-4 w-4 text-neutral-500" />
                  Isolated workspaces
                </h3>
                <p className="text-sm text-neutral-400">
                  Each agent gets its own VS Code instance with isolated git worktrees. 
                  No more conflicts or accidental overwrites.
                </p>
              </div>
              
              <div>
                <h3 className="font-semibold mb-2 flex items-center gap-2">
                  <Terminal className="h-4 w-4 text-neutral-500" />
                  Multi-agent support
                </h3>
                <p className="text-sm text-neutral-400">
                  Works with Claude Code, Codex, Gemini CLI, Amp, OpenCode, and more. 
                  Try Kimi K2, Qwen 3 Coder, and GLM-4.5 alongside Claude Opus.
                </p>
              </div>
              
              <div>
                <h3 className="font-semibold mb-2 flex items-center gap-2">
                  <Star className="h-4 w-4 text-neutral-500" />
                  Git-first workflow
                </h3>
                <p className="text-sm text-neutral-400">
                  Automatically opens git diff UI and terminal with your agent. 
                  Review changes instantly without context switching.
                </p>
              </div>
            </div>
            
            <div className="space-y-6">
              <div>
                <h3 className="font-semibold mb-2">Configurable sandboxes</h3>
                <p className="text-sm text-neutral-400">
                  Use Docker by default or configure with Freestyle, Morph, Daytona, Modal, Beam, or E2B.
                </p>
              </div>
              
              <div>
                <h3 className="font-semibold mb-2">Safer permissions</h3>
                <p className="text-sm text-neutral-400">
                  Makes <code className="px-1.5 py-0.5 bg-neutral-900 rounded text-xs">--dangerously-skip-permissions</code> actually safe 
                  with proper isolation.
                </p>
              </div>
              
              <div>
                <h3 className="font-semibold mb-2">Open source</h3>
                <p className="text-sm text-neutral-400">
                  MIT licensed. Contribute on GitHub or fork for your own needs.
                </p>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Caveats */}
      <section className="py-16 px-4 sm:px-6 lg:px-8 border-t border-neutral-900">
        <div className="max-w-4xl mx-auto">
          <h2 className="text-2xl font-bold mb-6">Current limitations</h2>
          <div className="space-y-4 text-neutral-400">
            <p>
              The bottleneck of running many agents in parallel is still reviewing and verifying the work. 
              We're working on:
            </p>
            <ul className="list-disc list-inside space-y-2 ml-4">
              <li>"Vercel preview environments" for any repo with a proper devcontainer.json</li>
              <li>Computer-using agents to click around and take before/after screenshots for UI changes</li>
              <li>A real "manager" abstraction above manually reviewing code and merging PRs</li>
            </ul>
          </div>
        </div>
      </section>

      {/* CTA */}
      <section className="py-16 px-4 sm:px-6 lg:px-8 border-t border-neutral-900">
        <div className="max-w-4xl mx-auto text-center">
          <h2 className="text-2xl font-bold mb-4">Ready to parallelize your coding?</h2>
          <p className="text-neutral-400 mb-8">
            Install in seconds. No credit card required.
          </p>
          
          <div className="flex flex-col sm:flex-row gap-4 justify-center mb-8">
            <div className="bg-neutral-900 border border-neutral-800 rounded-lg px-6 py-3 font-mono text-sm flex items-center justify-between">
              <span>bunx cmux</span>
              <button
                onClick={() => copyToClipboard('bunx cmux')}
                className="ml-4 text-neutral-500 hover:text-white transition-colors"
              >
                {copiedCommand === 'bunx cmux' ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}
              </button>
            </div>
          </div>

          <div className="flex items-center justify-center gap-4 text-sm">
            <a 
              href="https://github.com/manaflow-ai/cmux" 
              target="_blank" 
              rel="noopener noreferrer"
              className="text-neutral-400 hover:text-white transition-colors flex items-center gap-2"
            >
              <Github className="h-4 w-4" />
              View on GitHub
            </a>
            <span className="text-neutral-700">•</span>
            <a 
              href="https://cal.com/team/manaflow/meeting" 
              target="_blank" 
              rel="noopener noreferrer"
              className="text-neutral-400 hover:text-white transition-colors flex items-center gap-2"
            >
              Book a call
              <ExternalLink className="h-3 w-3" />
            </a>
            <span className="text-neutral-700">•</span>
            <Link to="/dashboard" className="text-neutral-400 hover:text-white transition-colors">
              Documentation
            </Link>
          </div>
        </div>
      </section>

      {/* Footer */}
      <footer className="py-8 px-4 sm:px-6 lg:px-8 border-t border-neutral-900">
        <div className="max-w-4xl mx-auto flex flex-col sm:flex-row justify-between items-center gap-4">
          <div className="flex items-center gap-2">
            <Terminal className="h-4 w-4 text-neutral-500" />
            <span className="text-sm text-neutral-500 font-mono">cmux by manaflow</span>
          </div>
          <div className="flex items-center gap-6 text-sm text-neutral-500">
            <a href="https://github.com/manaflow-ai/cmux" className="hover:text-white transition-colors">GitHub</a>
            <a href="https://twitter.com" className="hover:text-white transition-colors">Twitter</a>
            <a href="https://discord.com" className="hover:text-white transition-colors">Discord</a>
          </div>
        </div>
      </footer>
    </div>
  )
}