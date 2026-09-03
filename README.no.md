> Denne oversettelsen ble generert av Claude. Hvis du har forslag til forbedringer, send gjerne en PR.

<h1 align="center">cmux</h1>
<p align="center">En Ghostty-basert macOS-terminal med vertikale faner og varsler for AI-kodeagenter</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Last ned cmux for macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.vi.md">Tiếng Việt</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | Norsk | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/github/stars/manaflow-ai/cmux?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmux skjermbilde" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Demovideo</a> · <a href="https://cmux.com/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## Funksjoner

<table>
<tr>
<td width="40%" valign="middle">
<h3>Varselringer</h3>
Paneler får en blå ring og faner lyser opp når kodeagenter trenger oppmerksomheten din
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Varselringer" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Varselpanel</h3>
Se alle ventende varsler på ett sted, hopp til det nyeste uleste
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Varselmerke i sidefeltet" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Innebygd nettleser</h3>
Del en nettleser ved siden av terminalen med et skriptbart API portet fra <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Innebygd nettleser" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Vertikale + horisontale faner</h3>
Sidefeltet viser git-gren, tilknyttet PR-status/nummer, arbeidsmappe, lyttende porter og siste varselstekst. Del horisontalt og vertikalt.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Vertikale faner og delte paneler" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>SSH</h3>
<code>cmux ssh user@remote</code> oppretter et arbeidsområde for en ekstern maskin. Nettleserpaneler rutes gjennom det eksterne nettverket, så localhost bare fungerer. Dra et bilde inn i en ekstern sesjon for å laste opp via scp.
</td>
<td width="60%">
<img src="./docs/assets/ssh.png" alt="cmux SSH" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Claude Code Teams</h3>
<code>cmux claude-teams</code> kjører Claude Codes lagkameratmodus med én kommando. Lagkamerater opprettes som native delinger med metadata i sidefeltet og varsler. Ingen tmux nødvendig.
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **Nettleserimport** — Importer informasjonskapsler, historikk og sesjoner fra Chrome, Firefox, Arc og 20+ andre nettlesere slik at nettleserpaneler starter autentisert
- **Egendefinerte kommandoer** — Definer prosjektspesifikke handlinger i [`cmux.json`](https://cmux.com/docs/custom-commands) som startes fra kommandopaletten
- **Skriptbar** — CLI og socket API for å opprette arbeidsområder, dele paneler, sende tastetrykk og automatisere nettleseren
- **Nativ macOS-app** — Bygget med Swift og AppKit, ikke Electron. Rask oppstart, lavt minneforbruk.
- **Ghostty-kompatibel** — Leser din eksisterende `~/.config/ghostty/config` for temaer, skrifttyper og farger
- **GPU-akselerert** — Drevet av libghostty for jevn gjengivelse
- **Tastatursnarveier** — [Omfattende snarveier](https://cmux.com/docs/keyboard-shortcuts) for arbeidsområder, delinger, nettleser og mer
- **Åpen kildekode** — Gratis og GPL-lisensiert

## Installasjon

### DMG (anbefalt)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Last ned cmux for macOS" width="180" />
</a>

Åpne `.dmg`-filen og dra cmux til Programmer-mappen. cmux oppdaterer seg selv automatisk via Sparkle, så du trenger bare å laste ned én gang.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

For å oppdatere senere:

```bash
brew upgrade --cask cmux
```

Ved første oppstart kan macOS be deg bekrefte åpning av en app fra en identifisert utvikler. Klikk **Åpne** for å fortsette.

## Hvorfor cmux?

Jeg kjører mange Claude Code- og Codex-sesjoner parallelt. Jeg brukte Ghostty med en haug delte paneler, og stolte på native macOS-varsler for å vite når en agent trengte meg. Men Claude Codes varselstekst er alltid bare "Claude is waiting for your input" uten kontekst, og med nok faner åpne kunne jeg ikke engang lese titlene lenger.

Jeg prøvde noen kodeorkestratorer, men de fleste var Electron/Tauri-apper og ytelsen irriterte meg. Jeg foretrekker også terminalen siden GUI-orkestratorer låser deg inn i arbeidsflyten deres. Så jeg bygde cmux som en nativ macOS-app i Swift/AppKit. Den bruker libghostty for terminalgjengivelse og leser din eksisterende Ghostty-konfigurasjon for temaer, skrifttyper og farger.

Hovedtilleggene er sidefeltet og varselsystemet. Sidefeltet har vertikale faner som viser git-gren, tilknyttet PR-status/nummer, arbeidsmappe, lyttende porter og siste varselstekst for hvert arbeidsområde. Varselsystemet fanger opp terminalsekvenser (OSC 9/99/777) og har en CLI (`cmux notify`) du kan koble til agentkroker for Claude Code, OpenCode osv. Når en agent venter, får panelet en blå ring og fanen lyser opp i sidefeltet, så jeg kan se hvilken som trenger meg på tvers av delinger og faner. Cmd+Shift+U hopper til det nyeste uleste.

Den innebygde nettleseren har et skriptbart API portet fra [agent-browser](https://github.com/vercel-labs/agent-browser). Agenter kan ta overblikk over tilgjengelighetstreet, hente elementreferanser, klikke, fylle ut skjemaer og kjøre JS. Du kan dele et nettleserpanel ved siden av terminalen og la Claude Code samhandle med utviklingsserveren din direkte.

Alt er skriptbart gjennom CLI og socket API — opprett arbeidsområder/faner, del paneler, send tastetrykk, åpne URLer i nettleseren.

## The Zen of cmux

cmux er ikke foreskrivende om hvordan utviklere bruker verktøyene sine. Det er en terminal og nettleser med en CLI, og resten er opp til deg.

cmux er en primitiv, ikke en løsning. Det gir deg en terminal, en nettleser, varsler, arbeidsområder, delinger, faner og en CLI for å kontrollere alt sammen. cmux tvinger deg ikke inn i en bestemt måte å bruke kodeagenter på. Hva du bygger med primitivene er ditt.

De beste utviklerne har alltid bygget sine egne verktøy. Ingen har funnet ut den beste måten å jobbe med agenter på ennå, og teamene som bygger lukkede produkter har definitivt ikke gjort det heller. Utviklerne som er nærmest sine egne kodebaser vil finne det ut først.

Gi en million utviklere komponerbare primitiver og de vil kollektivt finne de mest effektive arbeidsflytene raskere enn noe produktteam kunne designet ovenfra og ned.

## Dokumentasjon

For mer informasjon om hvordan du konfigurerer cmux, [gå til dokumentasjonen vår](https://cmux.com/docs/getting-started?utm_source=readme).

## Tastatursnarveier

### Arbeidsområder

| Snarvei | Handling |
|----------|--------|
| ⌘ N | Nytt arbeidsområde |
| ⌘ 1–8 | Hopp til arbeidsområde 1–8 |
| ⌘ 9 | Hopp til siste arbeidsområde |
| ⌃ ⌘ ] | Neste arbeidsområde |
| ⌃ ⌘ [ | Forrige arbeidsområde |
| ⌘ ⇧ W | Lukk arbeidsområde |
| ⌘ ⇧ R | Gi nytt navn til arbeidsområde |
| ⌥ ⌘ E | Rediger arbeidsområdebeskrivelse |
| ⌘ B | Vis/skjul sidefelt |
| ⌥ ⌘ B | Vis/skjul høyre sidefelt |
| ⌘ ⇧ E | Veksle fokus til høyre sidefelt |

### Overflater

| Snarvei | Handling |
|----------|--------|
| ⌘ T | Ny overflate |
| ⌘ ⇧ ] | Neste overflate |
| ⌘ ⇧ [ | Forrige overflate |
| ⌃ Tab | Neste overflate |
| ⌃ ⇧ Tab | Forrige overflate |
| ⌃ 1–8 | Hopp til overflate 1–8 |
| ⌃ 9 | Hopp til siste overflate |
| ⌘ W | Lukk overflate |

### Delte paneler

| Snarvei | Handling |
|----------|--------|
| ⌘ D | Del til høyre |
| ⌘ ⇧ D | Del nedover |
| ⌥ ⌘ ← → ↑ ↓ | Fokuser panel i retning |
| ⌘ ⇧ H | Blink fokusert panel |

### Nettleser

Nettleserens utviklerverktøysnarveier følger Safari-standarder og kan tilpasses i `Innstillinger → Tastatursnarveier`.
Snarveier for navigasjon i kommandopaletten, inkludert ⌃ P, kan også tilpasses og kan fjernes slik at tastetrykket når den aktive terminalen.

| Snarvei | Handling |
|----------|--------|
| ⌘ ⇧ L | Åpne nettleser i deling |
| ⌘ L | Fokuser adressefeltet |
| ⌘ [ | Tilbake |
| ⌘ ] | Fremover |
| ⌘ R | Last inn siden på nytt |
| ⌥ ⌘ I | Vis/skjul utviklerverktøy (Safari-standard) |
| ⌥ ⌘ C | Vis JavaScript-konsoll (Safari-standard) |

### Varsler

| Snarvei | Handling |
|----------|--------|
| ⌘ I | Vis varselpanel |
| ⌘ ⇧ U | Hopp til nyeste uleste |
| ⌥ ⌘ U | Veksle ulest-status for gjeldende element |
| ⌃ ⌘ U | Merk gjeldende element som eldste uleste og hopp til neste nyeste uleste |

### Søk

| Snarvei | Handling |
|----------|--------|
| ⌘ F | Søk |
| ⌘ ⇧ F | Søk i mappe |
| ⌘ G / ⌥ ⌘ G | Søk neste / forrige |
| ⌥ ⌘ ⇧ F | Skjul søkelinje |
| ⌘ E | Bruk utvalg til søk |

### Terminal

| Snarvei | Handling |
|----------|--------|
| ⌘ K | Tøm rullingshistorikk |
| ⌘ C | Kopier (med utvalg) |
| ⌘ V | Lim inn |
| ⌘ + / ⌘ - | Øk / reduser skriftstørrelse |
| ⌘ 0 | Tilbakestill skriftstørrelse |

### Vindu

| Snarvei | Handling |
|----------|--------|
| ⌘ ⇧ N | Nytt vindu |
| ⌘ ⇧ O | Gjenåpne forrige sesjon |
| ⌘ , | Innstillinger |
| ⌘ ⇧ , | Last inn konfigurasjon på nytt |
| ⌘ Q | Avslutt |

## Nattlige bygg

[Last ned cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY er en separat app med sin egen bundle-ID, så den kjører ved siden av den stabile versjonen. Bygges automatisk fra den siste `main`-commiten og oppdateres automatisk via sin egen Sparkle-feed.

Rapporter feil i nightly på [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) eller i [#nightly-bugs på Discord](https://discord.gg/xsgFEVrWCZ).

## Sesjonsgjenoppretting

Når du avslutter cmux, lagres den nåværende sesjonen. Ved omstart gjenoppretter cmux tilstand som eies av appen:
- Vindu-/arbeidsområde-/panellayout
- Arbeidsmapper
- Terminal-rullingshistorikk (best effort)
- Nettleser-URL og navigasjonshistorikk

cmux tar ikke checkpoint av vilkårlig aktiv prosesstilstand. tmux, vim, shell og terminalapper uten støtte åpnes igjen som vanlige terminaler.

Støttede agentøkter kan gjenopptas når hooks har lagret en native sesjons-ID. Installer hooks etter at du har installert agent-CLI-en slik at binærfilen er på `PATH`:

```bash
cmux hooks setup
cmux hooks setup codex
cmux hooks setup --agent opencode
```

`cmux hooks setup` installerer støttede agenter den finner, og skriver ut et sammendrag for agenter som hoppes over. Støttede resume-integrasjoner inkluderer Claude Code, Codex, Grok, OpenCode, Pi, Amp, Cursor CLI, Gemini, Rovo Dev, Copilot, CodeBuddy, Factory og Qoder. Claude Code håndteres av cmux Claude-wrapperen når Claude-integrasjon er aktivert i Innstillinger.

Avanserte brukere og integrasjoner kan knytte en egendefinert gjenopptakskommando til gjeldende terminal-surface. Dette er nyttig for verktøy med egen varig tilstand, som tmux-sesjoner eller egendefinerte agent-CLI-er:

```bash
cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work
```

Bindingen forblir knyttet til cmux-surfacen. Bindinger opprettet via offentlig CLI eller socket lagres for inspeksjon og manuell gjenopptakelse med mindre du godkjenner et signert kommandoprefiks for automatisk gjenopptakelse. Godkjente prefikser er også bundet til arbeidsmappen og de eksakte miljøverdiene, når de er til stede. Gjennomgå eller rediger godkjenninger i **Innstillinger > Terminal > Resume Commands**. cmux auto-kjører bare resume-bindinger den markerer som klarerte, for eksempel tmux-bindinger oppdaget fra levende prosesser eller brukergodkjente prefikser. Sensitive miljønøkler som tokens, passord, hemmeligheter og API-nøkler fjernes før en resume-binding lagres.

For å holde gjenopprettede agentterminaler i ro i stedet for å automatisk kjøre resume-kommandoene deres, slå av **Innstillinger > Terminal > Resume Agent Sessions on Reopen** eller angi dette i `~/.config/cmux/cmux.json`:

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

Dette deaktiverer bare automatiske resume-kommandoer for agenter. cmux gjenoppretter fortsatt den lagrede layouten, arbeidsmappene, rullingshistorikken og nettleserhistorikken.

Hvis du trenger å bruke det sist lagrede øyeblikksbildet manuelt på nytt, bruk:
- `File > Reopen Previous Session`
- `⌘ ⇧ O`
- `cmux restore-session`

Under panseret skriver cmux et versjonert øyeblikksbilde under `~/Library/Application Support/cmux/`, og agent-hooks skriver sesjonstilordninger under `~/.cmuxterm/`. Ved gjenoppretting bygger cmux layouten på nytt først, og kjører deretter den støttede agentens native resume-kommando når automatisk agentgjenopptakelse er aktivert.

Les hele veiledningen på <https://cmux.com/docs/session-restore>.

## FAQ

### Hvordan forholder cmux seg til Ghostty?

cmux er ikke en fork av Ghostty. Den bruker [libghostty](https://github.com/ghostty-org/ghostty) som et bibliotek for terminalgjengivelse, på samme måte som apper bruker WebKit for nettvisninger. Ghostty er en frittstående terminal; cmux er en annen app bygget oppå dens gjengivelsesmotor.

### Hvilke plattformer støttes?

Bare macOS, foreløpig. cmux er en nativ Swift + AppKit-app.

### Finnes det en iOS-app?

Ja, i beta. Par iPhonen din med Macen din fra Mobile Connect-vinduet og koble til terminalene dine fra telefonen, med valgfri videresending av terminalvarsler. Den leveres på TestFlight som cmux BETA. Se [iOS-dokumentasjonen](https://cmux.com/docs/ios).

### Hvilke kodeagenter fungerer cmux med?

Alle sammen. cmux er en terminal, så enhver agent som kjører i en terminal fungerer rett ut av boksen: Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, Goose, Amp, Cline, Cursor Agent og alt annet du kan starte fra kommandolinjen.

### Kan cmux orkestrere flere agenter og subagenter?

Ja. Når en agent oppretter subagenter eller lagkamerater, gjør cmux dem til native paneler og delinger i stedet for skjulte bakgrunnsprosesser. Den støtter [Claude Code teams](https://cmux.com/docs/agent-integrations/claude-code-teams) og [oh-my-opencode](https://cmux.com/docs/agent-integrations/oh-my-opencode) fler-modell-orkestrering, så hver agent i en kjøring er synlig og kontrollerbar.

### Kan jeg bruke cmux med eksterne maskiner?

Ja. Åpne arbeidsområder over SSH og koble til eksterne tmux-sesjoner, slik at agenter kan kjøre på en ekstern vert mens du styrer dem fra cmux. Se [SSH og ekstern](https://cmux.com/docs/ssh).

### Hvordan fungerer varsler?

Når en prosess trenger oppmerksomhet, viser cmux varselringer rundt paneler, uleste-merker i sidefeltet, en varsel-popover og et macOS-skrivebordsvarsel. Disse utløses automatisk via standard terminal-escape-sekvenser (OSC 9/99/777), eller du kan utløse dem med [cmux CLI](https://cmux.com/docs/notifications#cli-usage) og [agentkroker](https://cmux.com/docs/notifications#integration-examples). Enhver agent som støtter hooks eller OSC fungerer, inkludert Claude Code, Codex, OpenCode og pi.

### Er cmux programmerbar?

Ja. Hver handling er tilgjengelig gjennom cmux CLI og en Unix-socket: opprett arbeidsområder, åpne delte paneler, send input, les skjerminnhold, ta skjermbilder og styr den innebygde nettleseren. Se [CLI-referansen](https://cmux.com/docs/api) og dokumentasjonen for [nettleserautomatisering](https://cmux.com/docs/browser-automation).

### Hva kan den innebygde nettleseren gjøre?

cmux kan dele et ekte nettleserpanel ved siden av terminalen din, og den er fullstendig programmerbar: naviger, ta øyeblikksbilde av DOM-en, klikk, skriv, kjør JavaScript og les konsoll- og nettverksaktivitet over det samme socket API-et. Agenter bruker den til å verifisere sine egne nettendringer uten å forlate cmux. Se [nettleserautomatisering](https://cmux.com/docs/browser-automation).

### Har cmux skills?

Ja. Skills er gjenbrukbare arbeidsflyter du kan gi enhver agent som kjører i cmux, for ting som CLI-kontroll, automatisering av arbeidsområder, innstillinger og nettleseroverflater. Bla i den åpne samlingen på [cmux-skills](https://github.com/manaflow-ai/cmux-skills), eller les [skills-dokumentasjonen](https://cmux.com/docs/skills).

### Kan jeg tilpasse tastatursnarveier?

Terminaltastebindinger leses fra Ghostty-konfigurasjonsfilen din (`~/.config/ghostty/config`). cmux-spesifikke snarveier (arbeidsområder, delinger, nettleser, varsler) kan tilpasses i Innstillinger. Se [standardsnarveiene](https://cmux.com/docs/keyboard-shortcuts) for en fullstendig liste.

### Kan jeg tilpasse cmux?

Ja. Terminalgjengivelse bruker Ghostty-konfigurasjonen din, så temaer, skrifttyper, farger og markør overføres direkte. cmux' egne innstillinger i `~/.config/cmux/cmux.json` styrer sidefeltet, fanelinjen, delte paneler og oppførsel, og hver [tastatursnarvei](https://cmux.com/docs/keyboard-shortcuts) kan redigeres. Se [konfigurasjon](https://cmux.com/docs/configuration).

### Lagres sesjonene mine?

Ja. cmux gjenoppretter vinduene, arbeidsområdene, panelene, arbeidsmappene og rullingshistorikken når du starter på nytt, og tilstanden overlever en full omstart av datamaskinen, ikke bare avslutning av appen. Agentsesjoner som Claude Code, Codex og OpenCode kommer også tilbake. Se [sesjonsgjenoppretting](https://cmux.com/docs/session-restore).

### Hvordan sammenligner det seg med tmux?

tmux er en terminalmultiplekser som kjører inne i en hvilken som helst terminal. cmux er en nativ macOS-app med et GUI: vertikale faner, delte paneler, en innebygd nettleser og et socket API, alt innebygd, uten behov for konfigurasjonsfiler eller prefiks-taster. Når det er sagt, kjører mange gjerne cmux med SSH og tmux sammen, og cmux kan koble til de eksterne tmux-sesjonene dine nativt ([beta](https://cmux.com/docs/remote-tmux)).

### Er cmux gratis?

Ja, cmux er gratis å bruke. Kildekoden er tilgjengelig på [GitHub](https://github.com/manaflow-ai/cmux).

### Hvordan kan jeg støtte cmux?

cmux er gratis og åpen kildekode, og vil alltid være det. Hvis du vil støtte utviklingen og få tidlig tilgang til det som kommer, inkludert cmux AI, iOS-appen og Cloud VMs, sjekk ut [cmux Founders Edition](https://github.com/manaflow-ai/cmux#founders-edition).

### Jeg har en funksjonsforespørsel eller fant en feil?

Vi vil gjerne høre det. Åpne en [issue](https://github.com/manaflow-ai/cmux/issues) eller [pull request](https://github.com/manaflow-ai/cmux/pulls) på GitHub, eller [send oss en e-post](mailto:founders@manaflow.com?subject=cmux%20feature%20request).

## Stjernehistorikk

<a href="https://www.star-history.com/?repos=manaflow-ai%2Fcmux&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=manaflow-ai/cmux&type=date&theme=dark&legend=top-left&sealed_token=N5E-Mdh7zIesE2fP9_q8wEZyOg3un2Ki7u61afJnUUu6ZIUEUsrH_dsPrA8CWrw12owIEezjOyhDiXcfIEoSzAlIybOqvxTk-xCpuXbpnFk86SkJzfErObW1u0MrAuLp-_tXZDM1kAMI2jMtAeXZK3_VEe2HH9dNyhXxgMTCns6c7lMmCJ_kSIgtooYf" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=manaflow-ai/cmux&type=date&legend=top-left&sealed_token=N5E-Mdh7zIesE2fP9_q8wEZyOg3un2Ki7u61afJnUUu6ZIUEUsrH_dsPrA8CWrw12owIEezjOyhDiXcfIEoSzAlIybOqvxTk-xCpuXbpnFk86SkJzfErObW1u0MrAuLp-_tXZDM1kAMI2jMtAeXZK3_VEe2HH9dNyhXxgMTCns6c7lMmCJ_kSIgtooYf" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=manaflow-ai/cmux&type=date&legend=top-left&sealed_token=N5E-Mdh7zIesE2fP9_q8wEZyOg3un2Ki7u61afJnUUu6ZIUEUsrH_dsPrA8CWrw12owIEezjOyhDiXcfIEoSzAlIybOqvxTk-xCpuXbpnFk86SkJzfErObW1u0MrAuLp-_tXZDM1kAMI2jMtAeXZK3_VEe2HH9dNyhXxgMTCns6c7lMmCJ_kSIgtooYf" />
 </picture>
</a>

## Bidra

Måter å engasjere seg:

- Følg oss på X for oppdateringer [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen), og [@austinywang](https://x.com/austinywang)
- Bli med i samtalen på [Discord](https://discord.gg/xsgFEVrWCZ)
- Opprett og delta i [GitHub-issues](https://github.com/manaflow-ai/cmux/issues) og [diskusjoner](https://github.com/manaflow-ai/cmux/discussions)
- Fortell oss hva du bygger med cmux

## Fellesskap

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [WhatsApp](https://chat.whatsapp.com/Fblh7FB58lOI2cx6ccdIqY?mode=gi_t)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

<p>
  <strong>WeChat:</strong> Skann QR-koden for å bli med i fellesskapet.<br />
  <img src="./docs/assets/wechat-community-qr.jpg" alt="WeChat-QR-kode for å bli med i cmux-fellesskapet" width="240" />
</p>

## Grunnleggerutgaven

cmux er gratis, åpen kildekode, og vil alltid være det. Hvis du vil støtte utviklingen og få tidlig tilgang til det som kommer:

**[Få Grunnleggerutgaven](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **Prioriterte funksjonsforespørsler/feilrettinger**
- **Tidlig tilgang: cmux AI som gir deg kontekst om hvert arbeidsområde, fane og panel**
- **Tidlig tilgang: iOS-app med terminaler synkronisert mellom desktop og telefon**
- **Tidlig tilgang: Cloud VMs**
- **Tidlig tilgang: Stemmemodus**
- **Min personlige iMessage/WhatsApp**

## Lisens

cmux er åpen kildekode under [GPL-3.0-or-later](LICENSE).

Hvis organisasjonen din ikke kan overholde GPL, er en kommersiell lisens tilgjengelig. Kontakt [founders@manaflow.com](mailto:founders@manaflow.com) for detaljer.
