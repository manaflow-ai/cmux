> Denne oversættelse er genereret af Claude. Har du forslag til forbedringer, er du velkommen til at oprette en PR.

<h1 align="center">cmux</h1>
<p align="center">En Ghostty-baseret macOS-terminal med lodrette faner og notifikationer til AI-kodningsagenter</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Download cmux til macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.vi.md">Tiếng Việt</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | Dansk | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/github/stars/manaflow-ai/cmux?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmux skærmbillede" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Demovideo</a> · <a href="https://cmux.com/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## Funktioner

<table>
<tr>
<td width="40%" valign="middle">
<h3>Notifikationsringe</h3>
Paneler får en blå ring, og faner lyser op, når kodningsagenter har brug for din opmærksomhed
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Notifikationsringe" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Notifikationspanel</h3>
Se alle ventende notifikationer ét sted, hop til den seneste ulæste
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Notifikationsbadge i sidebjælken" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Indbygget browser</h3>
Del en browser ved siden af din terminal med en scriptbar API porteret fra <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Indbygget browser" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Lodrette + vandrette faner</h3>
Sidebjælken viser git-branch, tilknyttet PR-status/nummer, arbejdsmappe, lyttende porte og seneste notifikationstekst. Del vandret og lodret.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Lodrette faner og delte paneler" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>SSH</h3>
<code>cmux ssh user@remote</code> opretter et workspace til en fjernmaskine. Browserpaneler rutes gennem fjernnetværket, så localhost bare virker. Træk et billede ind i en fjernsession for at uploade via scp.
</td>
<td width="60%">
<img src="./docs/assets/ssh.png" alt="cmux SSH" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Claude Code Teams</h3>
<code>cmux claude-teams</code> kører Claude Codes holdkammeratstilstand med én kommando. Holdkammerater oprettes som native opdelinger med metadata i sidebjælken og notifikationer. Ingen tmux påkrævet.
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **Browserimport** — Importér cookies, historik og sessioner fra Chrome, Firefox, Arc og 20+ andre browsere, så browserpaneler starter autentificerede
- **Brugerdefinerede kommandoer** — Definér projektspecifikke handlinger i [`cmux.json`](https://cmux.com/docs/custom-commands), der startes fra kommandopaletten
- **Scriptbar** — CLI og socket API til at oprette workspaces, dele paneler, sende tastetryk og automatisere browseren
- **Nativ macOS-app** — Bygget med Swift og AppKit, ikke Electron. Hurtig opstart, lavt hukommelsesforbrug.
- **Ghostty-kompatibel** — Læser din eksisterende `~/.config/ghostty/config` til temaer, skrifttyper og farver
- **GPU-accelereret** — Drevet af libghostty til jævn rendering
- **Tastaturgenveje** — [Omfattende genveje](https://cmux.com/docs/keyboard-shortcuts) til workspaces, opdelinger, browser og mere
- **Open source** — Gratis og GPL-licenseret

## Installation

### DMG (anbefalet)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Download cmux til macOS" width="180" />
</a>

Åbn `.dmg`-filen og træk cmux til din Programmer-mappe. cmux opdaterer sig selv automatisk via Sparkle, så du behøver kun at downloade én gang.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

For at opdatere senere:

```bash
brew upgrade --cask cmux
```

Ved første start kan macOS bede dig om at bekræfte åbning af en app fra en identificeret udvikler. Klik på **Åbn** for at fortsætte.

## Hvorfor cmux?

Jeg kører mange Claude Code- og Codex-sessioner parallelt. Jeg brugte Ghostty med en masse delte paneler og stolede på native macOS-notifikationer til at vide, hvornår en agent havde brug for mig. Men Claude Codes notifikationstekst er altid bare "Claude is waiting for your input" uden kontekst, og med nok åbne faner kunne jeg ikke engang læse titlerne længere.

Jeg prøvede et par kodningsorkestratore, men de fleste var Electron/Tauri-apps, og ydelsen irriterede mig. Jeg foretrækker også bare terminalen, da GUI-orkestratore låser dig ind i deres arbejdsgang. Så jeg byggede cmux som en nativ macOS-app i Swift/AppKit. Den bruger libghostty til terminal-rendering og læser din eksisterende Ghostty-konfiguration til temaer, skrifttyper og farver.

De vigtigste tilføjelser er sidebjælken og notifikationssystemet. Sidebjælken har lodrette faner, der viser git-branch, tilknyttet PR-status/nummer, arbejdsmappe, lyttende porte og den seneste notifikationstekst for hvert workspace. Notifikationssystemet opfanger terminalsekvenser (OSC 9/99/777) og har en CLI (`cmux notify`), du kan koble til agent-hooks for Claude Code, OpenCode osv. Når en agent venter, får dens panel en blå ring, og fanen lyser op i sidebjælken, så jeg kan se, hvilken der har brug for mig på tværs af opdelinger og faner. Cmd+Shift+U hopper til den seneste ulæste.

Den indbyggede browser har en scriptbar API porteret fra [agent-browser](https://github.com/vercel-labs/agent-browser). Agenter kan tage et snapshot af tilgængelighedstræet, få elementreferencer, klikke, udfylde formularer og evaluere JS. Du kan dele et browserpanel ved siden af din terminal og lade Claude Code interagere direkte med din udviklingsserver.

Alt er scriptbart gennem CLI og socket API — opret workspaces/faner, del paneler, send tastetryk, åbn URL'er i browseren.

## The Zen of cmux

cmux foreskriver ikke, hvordan udviklere bruger deres værktøjer. Det er en terminal og browser med en CLI, resten er op til dig.

cmux er en primitiv, ikke en løsning. Det giver dig en terminal, en browser, notifikationer, workspaces, opdelinger, faner og en CLI til at styre det hele. cmux tvinger dig ikke ind i en forudbestemt måde at bruge kodningsagenter på. Hvad du bygger med primitiverne, er dit eget.

De bedste udviklere har altid bygget deres egne værktøjer. Ingen har endnu fundet den bedste måde at arbejde med agenter på, og holdene bag lukkede produkter har heller ikke. De udviklere, der er tættest på deres egne kodebaser, vil finde ud af det først.

Giv en million udviklere komponerbare primitiver, og de vil kollektivt finde de mest effektive arbejdsgange hurtigere, end noget produkthold kunne designe oppefra.

## Dokumentation

For mere information om konfiguration af cmux, [se vores dokumentation](https://cmux.com/docs/getting-started?utm_source=readme).

## Tastaturgenveje

### Workspaces

| Genvej | Handling |
|----------|--------|
| ⌘ N | Nyt workspace |
| ⌘ 1–8 | Hop til workspace 1–8 |
| ⌘ 9 | Hop til sidste workspace |
| ⌃ ⌘ ] | Næste workspace |
| ⌃ ⌘ [ | Forrige workspace |
| ⌘ ⇧ W | Luk workspace |
| ⌘ ⇧ R | Omdøb workspace |
| ⌥ ⌘ E | Redigér workspace-beskrivelse |
| ⌘ B | Skjul/vis sidebjælke |
| ⌥ ⌘ B | Skjul/vis højre sidebjælke |
| ⌘ ⇧ E | Skift fokus til højre sidebjælke |

### Overflader

| Genvej | Handling |
|----------|--------|
| ⌘ T | Ny overflade |
| ⌘ ⇧ ] | Næste overflade |
| ⌘ ⇧ [ | Forrige overflade |
| ⌃ Tab | Næste overflade |
| ⌃ ⇧ Tab | Forrige overflade |
| ⌃ 1–8 | Hop til overflade 1–8 |
| ⌃ 9 | Hop til sidste overflade |
| ⌘ W | Luk overflade |

### Delte Paneler

| Genvej | Handling |
|----------|--------|
| ⌘ D | Del til højre |
| ⌘ ⇧ D | Del nedad |
| ⌥ ⌘ ← → ↑ ↓ | Fokuser panel retningsbestemt |
| ⌘ ⇧ H | Blink fokuseret panel |

### Browser

Browserens udviklerværktøjsgenveje følger Safaris standarder og kan tilpasses i `Indstillinger → Tastaturgenveje`.
Navigationsgenveje til kommandopaletten, herunder ⌃ P, kan også tilpasses og ryddes, så tastetrykket når den aktive terminal.

| Genvej | Handling |
|----------|--------|
| ⌘ ⇧ L | Åbn browser i opdeling |
| ⌘ L | Fokuser adresselinjen |
| ⌘ [ | Tilbage |
| ⌘ ] | Frem |
| ⌘ R | Genindlæs side |
| ⌥ ⌘ I | Slå Udviklerværktøjer til/fra (Safari-standard) |
| ⌥ ⌘ C | Vis JavaScript-konsol (Safari-standard) |

### Notifikationer

| Genvej | Handling |
|----------|--------|
| ⌘ I | Vis notifikationspanel |
| ⌘ ⇧ U | Hop til seneste ulæste |
| ⌥ ⌘ U | Skift det aktuelle elements ulæst-status |
| ⌃ ⌘ U | Markér det aktuelle element som ældste ulæste og hop til næste seneste ulæste |

### Søg

| Genvej | Handling |
|----------|--------|
| ⌘ F | Søg |
| ⌘ ⇧ F | Søg i mappe |
| ⌘ G / ⌥ ⌘ G | Find næste / forrige |
| ⌥ ⌘ ⇧ F | Skjul søgelinje |
| ⌘ E | Brug markering til søgning |

### Terminal

| Genvej | Handling |
|----------|--------|
| ⌘ K | Ryd scrollback |
| ⌘ C | Kopiér (med markering) |
| ⌘ V | Indsæt |
| ⌘ + / ⌘ - | Forøg / formindsk skriftstørrelse |
| ⌘ 0 | Nulstil skriftstørrelse |

### Vindue

| Genvej | Handling |
|----------|--------|
| ⌘ ⇧ N | Nyt vindue |
| ⌘ ⇧ O | Genåbn forrige session |
| ⌘ , | Indstillinger |
| ⌘ ⇧ , | Genindlæs konfiguration |
| ⌘ Q | Afslut |

## Nightly Builds

[Download cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY er en separat app med sit eget bundle-ID, så den kører side om side med den stabile version. Bygges automatisk fra det seneste `main`-commit og opdaterer sig selv automatisk via sit eget Sparkle-feed.

Rapportér nightly-fejl på [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) eller i [#nightly-bugs på Discord](https://discord.gg/xsgFEVrWCZ).

## Sessionsgenoprettelse

Når du afslutter cmux, gemmes den aktuelle session. Ved genstart genopretter cmux
app-ejet tilstand:
- Vindue/workspace/panel-layout
- Arbejdsmapper
- Terminal-scrollback (best effort)
- Browser-URL og navigationshistorik

cmux tager ikke checkpoints af vilkårlig aktiv procestilstand. tmux, vim, shells og
ikke-understøttede terminalapps åbnes igen som normale terminaler.

Understøttede agent-sessioner kan genoptages, når hooks har gemt et native sessions-ID.
Installér hooks efter installation af agentens CLI, så dens binær er på `PATH`:

```bash
cmux hooks setup
cmux hooks setup codex
cmux hooks setup --agent opencode
```

`cmux hooks setup` installerer de understøttede agenter, den kan finde, og udskriver en oversigt
over sprungne agenter. Understøttede genoptagelsesintegrationer omfatter Claude Code, Codex,
Grok, OpenCode, Pi, Amp, Cursor CLI, Gemini, Rovo Dev, Copilot, CodeBuddy,
Factory og Qoder. Claude Code håndteres af cmux' Claude-wrapper, når Claude-integration
er aktiveret i Indstillinger.

Avancerede brugere og integrationer kan knytte en brugerdefineret genoptagelseskommando til den
aktuelle terminal-surface. Det er nyttigt for værktøjer med egen varig tilstand, som
tmux-sessioner eller brugerdefinerede agent-CLI'er:

```bash
cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work
```

Bindingen forbliver knyttet til cmux-surfacen. Bindinger oprettet via offentlig CLI eller socket
gemmes til inspektion og manuel genoptagelse, medmindre du godkender et signeret kommandopræfiks
til automatisk genoptagelse. Godkendte præfikser er også bundet til arbejdsmappen og de præcise
miljøværdier, når de er til stede. Gennemse eller redigér godkendelser i
**Indstillinger > Terminal > Genoptagelseskommandoer**. cmux auto-kører kun genoptagelsesbindinger,
som den markerer som betroede, for eksempel tmux-bindinger fundet fra live processer eller
brugergodkendte præfikser. Følsomme miljønøgler som tokens, adgangskoder, hemmeligheder og
API-nøgler fjernes, før en genoptagelsesbinding gemmes.

For at holde genoprettede agent-terminaler inaktive i stedet for automatisk at køre deres genoptagelseskommandoer,
slå **Indstillinger > Terminal > Genoptag agent-sessioner ved genåbning** fra eller angiv dette i
`~/.config/cmux/cmux.json`:

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

Dette deaktiverer kun de automatiske agent-genoptagelseskommandoer. cmux genopretter stadig det gemte layout,
arbejdsmapperne, scrollback og browserhistorikken.

Hvis du har brug for at anvende det senest gemte snapshot manuelt igen, brug:
- `Arkiv > Genåbn forrige session`
- `⌘ ⇧ O`
- `cmux restore-session`

Under motorhjelmen skriver cmux et versioneret snapshot under
`~/Library/Application Support/cmux/`, og agent-hooks skriver sessionsmapninger
under `~/.cmuxterm/`. Ved genoprettelse genopbygger cmux først layoutet og kører derefter den
understøttede agents native genoptagelseskommando, når automatisk agent-genoptagelse er aktiveret.

Læs den fulde guide på <https://cmux.com/docs/session-restore>.

## FAQ

### Hvordan forholder cmux sig til Ghostty?

cmux er ikke en fork af Ghostty. Den bruger [libghostty](https://github.com/ghostty-org/ghostty) som et bibliotek til terminal-rendering, på samme måde som apps bruger WebKit til webvisninger. Ghostty er en selvstændig terminal; cmux er en anden app bygget oven på dens rendering-motor.

### Hvilke platforme understøtter den?

Kun macOS indtil videre. cmux er en nativ Swift + AppKit-app.

### Findes der en iOS-app?

Ja, i beta. Par din iPhone med din Mac fra Mobile Connect-vinduet og tilslut dig dine terminaler fra din telefon, med valgfri videresendelse af terminalnotifikationer. Den udgives på TestFlight som cmux BETA. Se [iOS-dokumentationen](https://cmux.com/docs/ios).

### Hvilke kodningsagenter fungerer cmux med?

Alle sammen. cmux er en terminal, så enhver agent, der kører i en terminal, fungerer fra start: Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, Goose, Amp, Cline, Cursor Agent og alt andet, du kan starte fra kommandolinjen.

### Kan cmux orkestrere flere agenter og underagenter?

Ja. Når en agent opretter underagenter eller holdkammerater, gør cmux dem til native paneler og opdelinger i stedet for skjulte baggrundsprocesser. Den understøtter [Claude Code teams](https://cmux.com/docs/agent-integrations/claude-code-teams) og [oh-my-opencode](https://cmux.com/docs/agent-integrations/oh-my-opencode) multi-model-orkestrering, så hver agent i en kørsel er synlig og kontrollerbar.

### Kan jeg bruge cmux med fjernmaskiner?

Ja. Åbn workspaces over SSH og tilslut dig fjern-tmux-sessioner, så agenter kan køre på en fjernvært, mens du styrer dem fra cmux. Se [SSH og fjern](https://cmux.com/docs/ssh).

### Hvordan fungerer notifikationer?

Når en proces har brug for opmærksomhed, viser cmux notifikationsringe omkring paneler, ulæst-badges i sidebjælken, en notifikations-popover og en macOS-skrivebordsnotifikation. Disse udløses automatisk via standard-terminal-escape-sekvenser (OSC 9/99/777), eller du kan udløse dem med [cmux CLI](https://cmux.com/docs/notifications#cli-usage) og [agent-hooks](https://cmux.com/docs/notifications#integration-examples). Enhver agent, der understøtter hooks eller OSC, fungerer, herunder Claude Code, Codex, OpenCode og pi.

### Er cmux programmerbar?

Ja. Hver handling er tilgængelig gennem cmux CLI og en Unix-socket: opret workspaces, åbn delte paneler, send input, læs skærmindhold, tag skærmbilleder og styr den indbyggede browser. Se [CLI-referencen](https://cmux.com/docs/api) og [browserautomatisering](https://cmux.com/docs/browser-automation)-dokumentationen.

### Hvad kan den indbyggede browser?

cmux kan dele et rigtigt browserpanel ved siden af din terminal, og det er fuldt programmerbart: navigér, tag snapshot af DOM, klik, skriv, evaluér JavaScript og læs konsol- og netværksaktivitet over den samme socket API. Agenter bruger den til at verificere deres egne web-ændringer uden at forlade cmux. Se [browserautomatisering](https://cmux.com/docs/browser-automation).

### Har cmux skills?

Ja. Skills er genanvendelige arbejdsgange, du kan give enhver agent, der kører i cmux, til ting som CLI-styring, workspace-automatisering, indstillinger og browser-surfaces. Gennemse den åbne samling på [cmux-skills](https://github.com/manaflow-ai/cmux-skills), eller læs [skills-dokumentationen](https://cmux.com/docs/skills).

### Kan jeg tilpasse tastaturgenveje?

Terminal-tastebindinger læses fra din Ghostty-konfigurationsfil (`~/.config/ghostty/config`). cmux-specifikke genveje (workspaces, opdelinger, browser, notifikationer) kan tilpasses i Indstillinger. Se [standardgenvejene](https://cmux.com/docs/keyboard-shortcuts) for en fuld liste.

### Kan jeg tilpasse cmux?

Ja. Terminal-rendering bruger din Ghostty-konfiguration, så temaer, skrifttyper, farver og markør overføres direkte. cmux' egne indstillinger i `~/.config/cmux/cmux.json` styrer sidebjælken, fanelinjen, delte paneler og adfærd, og enhver [tastaturgenvej](https://cmux.com/docs/keyboard-shortcuts) kan redigeres. Se [konfiguration](https://cmux.com/docs/configuration).

### Bliver mine sessioner gemt?

Ja. cmux genopretter dine vinduer, workspaces, paneler, arbejdsmapper og scrollback, når du genåbner, og tilstanden overlever en fuld computer-genstart, ikke kun at lukke appen. Agent-sessioner som Claude Code, Codex og OpenCode kommer også tilbage. Se [sessionsgenoprettelse](https://cmux.com/docs/session-restore).

### Hvordan kan den sammenlignes med tmux?

tmux er en terminal-multiplexer, der kører inde i enhver terminal. cmux er en nativ macOS-app med en GUI: lodrette faner, delte paneler, en indlejret browser og en socket API, alt indbygget, uden brug for konfigurationsfiler eller præfiks-taster. Når det er sagt, kører mange mennesker gerne cmux med SSH og tmux sammen, og cmux kan tilslutte sig dine fjern-tmux-sessioner nativt ([beta](https://cmux.com/docs/remote-tmux)).

### Er cmux gratis?

Ja, cmux er gratis at bruge. Kildekoden er tilgængelig på [GitHub](https://github.com/manaflow-ai/cmux).

### Hvordan kan jeg støtte cmux?

cmux er gratis og open source og vil altid være det. Hvis du vil støtte udviklingen og få tidlig adgang til det, der kommer, herunder cmux AI, iOS-appen og Cloud VM'er, så tjek [cmux Founders Edition](https://github.com/manaflow-ai/cmux#founders-edition).

### Jeg har et funktionsønske eller har fundet en fejl?

Vi vil gerne høre det. Opret en [issue](https://github.com/manaflow-ai/cmux/issues) eller [pull request](https://github.com/manaflow-ai/cmux/pulls) på GitHub, eller [send os en e-mail](mailto:founders@manaflow.com?subject=cmux%20feature%20request).

## Stjernehistorik

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## Bidrag

Måder at deltage:

- Følg os på X for opdateringer [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen) og [@austinywang](https://x.com/austinywang)
- Deltag i samtalen på [Discord](https://discord.gg/xsgFEVrWCZ)
- Opret og deltag i [GitHub issues](https://github.com/manaflow-ai/cmux/issues) og [diskussioner](https://github.com/manaflow-ai/cmux/discussions)
- Fortæl os, hvad du bygger med cmux

## Fællesskab

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Founder's Edition

cmux er gratis, open source og vil altid være det. Hvis du gerne vil støtte udviklingen og få tidlig adgang til det, der kommer:

**[Få Founder's Edition](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **Prioriterede funktionsønsker og fejlrettelser**
- **Tidlig adgang: cmux AI der giver dig kontekst om hvert workspace, fane og panel**
- **Tidlig adgang: iOS-app med terminaler synkroniseret mellem desktop og telefon**
- **Tidlig adgang: Cloud VM'er**
- **Tidlig adgang: Stemmetilstand**
- **Min personlige iMessage/WhatsApp**

## Licens

cmux er open source under [GPL-3.0-or-later](LICENSE).

Hvis din organisation ikke kan overholde GPL, er en kommerciel licens tilgængelig. Kontakt [founders@manaflow.com](mailto:founders@manaflow.com) for detaljer.
