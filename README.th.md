> การแปลนี้สร้างโดย Claude หากมีข้อเสนอแนะในการปรับปรุง กรุณาเปิด PR

<h1 align="center">cmux</h1>
<p align="center">เทอร์มินัล macOS ที่ใช้ Ghostty พร้อมแท็บแนวตั้งและการแจ้งเตือนสำหรับเอเจนต์เขียนโค้ด AI</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="ดาวน์โหลด cmux สำหรับ macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.vi.md">Tiếng Việt</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | ไทย | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/github/stars/manaflow-ai/cmux?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="ภาพหน้าจอ cmux" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ วิดีโอสาธิต</a> · <a href="https://cmux.com/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## คุณสมบัติ

<table>
<tr>
<td width="40%" valign="middle">
<h3>วงแหวนแจ้งเตือน</h3>
แพเนลจะมีวงแหวนสีน้ำเงินและแท็บจะสว่างขึ้นเมื่อเอเจนต์เขียนโค้ดต้องการความสนใจจากคุณ
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="วงแหวนแจ้งเตือน" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>แผงการแจ้งเตือน</h3>
ดูการแจ้งเตือนที่ค้างอยู่ทั้งหมดในที่เดียว กระโดดไปยังรายการที่ยังไม่อ่านล่าสุด
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="ป้ายแจ้งเตือนบนแถบด้านข้าง" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>เบราว์เซอร์ในแอป</h3>
แยกเบราว์เซอร์ไว้ข้างเทอร์มินัลของคุณ พร้อม API ที่เขียนสคริปต์ได้ซึ่งพอร์ตมาจาก <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="เบราว์เซอร์ในตัว" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>แท็บแนวตั้ง + แนวนอน</h3>
แถบด้านข้างแสดงสาขา git, สถานะ/หมายเลข PR ที่เชื่อมโยง, ไดเรกทอรีทำงาน, พอร์ตที่กำลังฟัง และข้อความแจ้งเตือนล่าสุด แยกได้ทั้งแนวนอนและแนวตั้ง
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="แท็บแนวตั้งและแพเนลที่แยก" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>SSH</h3>
<code>cmux ssh user@remote</code> สร้างพื้นที่ทำงานสำหรับเครื่องระยะไกล แพเนลเบราว์เซอร์จะกำหนดเส้นทางผ่านเครือข่ายระยะไกล ดังนั้น localhost จึงใช้งานได้เลย ลากรูปภาพเข้าไปในเซสชันระยะไกลเพื่ออัปโหลดผ่าน scp
</td>
<td width="60%">
<img src="./docs/assets/ssh.png" alt="cmux SSH" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Claude Code Teams</h3>
<code>cmux claude-teams</code> รันโหมดเพื่อนร่วมทีมของ Claude Code ด้วยคำสั่งเดียว เพื่อนร่วมทีมจะเกิดขึ้นเป็นแพเนลแยกแบบเนทีฟพร้อมข้อมูลเมตาบนแถบด้านข้างและการแจ้งเตือน ไม่ต้องใช้ tmux
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **นำเข้าเบราว์เซอร์** — นำเข้าคุกกี้ ประวัติ และเซสชันจาก Chrome, Firefox, Arc และเบราว์เซอร์อีกกว่า 20 ตัว เพื่อให้แพเนลเบราว์เซอร์เริ่มต้นในสถานะที่ล็อกอินแล้ว
- **คำสั่งกำหนดเอง** — กำหนดการกระทำเฉพาะโปรเจกต์ใน [`cmux.json`](https://cmux.com/docs/custom-commands) ที่เปิดใช้งานจาก command palette
- **เขียนโปรแกรมได้** — CLI และ socket API สำหรับสร้างพื้นที่ทำงาน แยกแพเนล ส่งการกดแป้นพิมพ์ และทำให้เบราว์เซอร์เป็นอัตโนมัติ
- **แอป macOS เนทีฟ** — สร้างด้วย Swift และ AppKit ไม่ใช่ Electron เริ่มต้นเร็ว ใช้หน่วยความจำน้อย
- **เข้ากันได้กับ Ghostty** — อ่านไฟล์ `~/.config/ghostty/config` ที่มีอยู่ของคุณสำหรับธีม ฟอนต์ และสี
- **เร่งความเร็วด้วย GPU** — ขับเคลื่อนด้วย libghostty เพื่อการเรนเดอร์ที่ลื่นไหล
- **คีย์ลัด** — [คีย์ลัดมากมาย](https://cmux.com/docs/keyboard-shortcuts) สำหรับพื้นที่ทำงาน การแยก เบราว์เซอร์ และอื่น ๆ
- **โอเพนซอร์ส** — ฟรีและใช้สัญญาอนุญาต GPL

## การติดตั้ง

### DMG (แนะนำ)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="ดาวน์โหลด cmux สำหรับ macOS" width="180" />
</a>

เปิดไฟล์ `.dmg` แล้วลาก cmux ไปยังโฟลเดอร์ Applications ของคุณ cmux อัปเดตอัตโนมัติผ่าน Sparkle ดังนั้นคุณจึงดาวน์โหลดเพียงครั้งเดียว

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

อัปเดตในภายหลัง:

```bash
brew upgrade --cask cmux
```

เมื่อเปิดใช้งานครั้งแรก macOS อาจขอให้คุณยืนยันการเปิดแอปจากนักพัฒนาที่ระบุตัวตนได้ คลิก **Open** เพื่อดำเนินการต่อ

## ทำไมต้อง cmux?

ผมรันเซสชัน Claude Code และ Codex จำนวนมากพร้อมกัน ผมเคยใช้ Ghostty กับแพเนลที่แยกออกมาเป็นจำนวนมาก และพึ่งพาการแจ้งเตือนเนทีฟของ macOS เพื่อรู้ว่าเมื่อใดที่เอเจนต์ต้องการผม แต่เนื้อหาการแจ้งเตือนของ Claude Code มักจะเป็นแค่ "Claude is waiting for your input" เสมอ โดยไม่มีบริบทใด ๆ และเมื่อเปิดแท็บมากพอ ผมก็อ่านชื่อแท็บไม่ออกอีกต่อไป

ผมลองเครื่องมือออร์เคสเตรชันสำหรับเขียนโค้ดอยู่ไม่กี่ตัว แต่ส่วนใหญ่เป็นแอป Electron/Tauri และประสิทธิภาพก็ทำให้ผมรำคาญ ผมยังชอบเทอร์มินัลมากกว่า เพราะออร์เคสเตรเตอร์แบบ GUI ล็อกคุณไว้กับเวิร์กโฟลว์ของพวกมัน ดังนั้นผมจึงสร้าง cmux เป็นแอป macOS เนทีฟด้วย Swift/AppKit มันใช้ libghostty สำหรับการเรนเดอร์เทอร์มินัล และอ่านการตั้งค่า Ghostty ที่มีอยู่ของคุณสำหรับธีม ฟอนต์ และสี

ส่วนเสริมหลักคือแถบด้านข้างและระบบการแจ้งเตือน แถบด้านข้างมีแท็บแนวตั้งที่แสดงสาขา git, สถานะ/หมายเลข PR ที่เชื่อมโยง, ไดเรกทอรีทำงาน, พอร์ตที่กำลังฟัง และข้อความแจ้งเตือนล่าสุดของแต่ละพื้นที่ทำงาน ระบบการแจ้งเตือนจะรับซีเควนซ์ของเทอร์มินัล (OSC 9/99/777) และมี CLI (`cmux notify`) ที่คุณสามารถเชื่อมเข้ากับ hooks ของเอเจนต์อย่าง Claude Code, OpenCode ฯลฯ เมื่อเอเจนต์กำลังรอ แพเนลของมันจะมีวงแหวนสีน้ำเงินและแท็บจะสว่างขึ้นบนแถบด้านข้าง ทำให้ผมบอกได้ว่าตัวไหนต้องการผมท่ามกลางแพเนลที่แยกและแท็บต่าง ๆ Cmd+Shift+U จะกระโดดไปยังรายการที่ยังไม่อ่านล่าสุด

เบราว์เซอร์ในแอปมี API ที่เขียนสคริปต์ได้ซึ่งพอร์ตมาจาก [agent-browser](https://github.com/vercel-labs/agent-browser) เอเจนต์สามารถถ่ายภาพ accessibility tree, รับ refs ของ element, คลิก, กรอกฟอร์ม และประเมิน JS คุณสามารถแยกแพเนลเบราว์เซอร์ไว้ข้างเทอร์มินัลของคุณ และให้ Claude Code โต้ตอบกับ dev server ของคุณได้โดยตรง

ทุกอย่างเขียนสคริปต์ได้ผ่าน CLI และ socket API — สร้างพื้นที่ทำงาน/แท็บ, แยกแพเนล, ส่งการกดแป้นพิมพ์, เปิด URL ในเบราว์เซอร์

## The Zen of cmux

cmux ไม่กำหนดตายตัวว่านักพัฒนาควรถือเครื่องมือของพวกเขาอย่างไร มันคือเทอร์มินัลและเบราว์เซอร์พร้อม CLI และที่เหลือก็ขึ้นอยู่กับคุณ

cmux เป็น primitive ไม่ใช่ solution มันมอบเทอร์มินัล เบราว์เซอร์ การแจ้งเตือน พื้นที่ทำงาน การแยก แท็บ และ CLI สำหรับควบคุมทั้งหมดให้คุณ cmux ไม่บังคับให้คุณใช้เอเจนต์เขียนโค้ดในแบบที่มีความคิดเห็นตายตัว สิ่งที่คุณสร้างขึ้นจาก primitive เหล่านี้เป็นของคุณ

นักพัฒนาที่เก่งที่สุดสร้างเครื่องมือของตนเองมาโดยตลอด ยังไม่มีใครค้นพบวิธีที่ดีที่สุดในการทำงานกับเอเจนต์ และทีมที่สร้างผลิตภัณฑ์แบบปิดก็ยังไม่พบเช่นกันอย่างแน่นอน นักพัฒนาที่อยู่ใกล้ชิดกับโค้ดเบสของตนเองที่สุดจะค้นพบมันก่อน

มอบ primitive ที่ประกอบเข้าด้วยกันได้ให้นักพัฒนาหนึ่งล้านคน แล้วพวกเขาจะร่วมกันค้นพบเวิร์กโฟลว์ที่มีประสิทธิภาพที่สุดได้เร็วกว่าทีมผลิตภัณฑ์ใด ๆ ที่ออกแบบจากบนลงล่าง

## เอกสาร

สำหรับข้อมูลเพิ่มเติมเกี่ยวกับวิธีกำหนดค่า cmux [ไปที่เอกสารของเรา](https://cmux.com/docs/getting-started?utm_source=readme)

## คีย์ลัด

### พื้นที่ทำงาน

| คีย์ลัด | การกระทำ |
|----------|--------|
| ⌘ N | พื้นที่ทำงานใหม่ |
| ⌘ 1–8 | กระโดดไปยังพื้นที่ทำงาน 1–8 |
| ⌘ 9 | กระโดดไปยังพื้นที่ทำงานสุดท้าย |
| ⌃ ⌘ ] | พื้นที่ทำงานถัดไป |
| ⌃ ⌘ [ | พื้นที่ทำงานก่อนหน้า |
| ⌘ ⇧ W | ปิดพื้นที่ทำงาน |
| ⌘ ⇧ R | เปลี่ยนชื่อพื้นที่ทำงาน |
| ⌥ ⌘ E | แก้ไขคำอธิบายพื้นที่ทำงาน |
| ⌘ B | สลับแถบด้านข้าง |
| ⌥ ⌘ B | สลับแถบด้านข้างขวา |
| ⌘ ⇧ E | สลับโฟกัสแถบด้านข้างขวา |

### พื้นผิว

| คีย์ลัด | การกระทำ |
|----------|--------|
| ⌘ T | พื้นผิวใหม่ |
| ⌘ ⇧ ] | พื้นผิวถัดไป |
| ⌘ ⇧ [ | พื้นผิวก่อนหน้า |
| ⌃ Tab | พื้นผิวถัดไป |
| ⌃ ⇧ Tab | พื้นผิวก่อนหน้า |
| ⌃ 1–8 | กระโดดไปยังพื้นผิว 1–8 |
| ⌃ 9 | กระโดดไปยังพื้นผิวสุดท้าย |
| ⌘ W | ปิดพื้นผิว |

### แพเนลที่แยก

| คีย์ลัด | การกระทำ |
|----------|--------|
| ⌘ D | แยกไปทางขวา |
| ⌘ ⇧ D | แยกลงด้านล่าง |
| ⌥ ⌘ ← → ↑ ↓ | โฟกัสแพเนลตามทิศทาง |
| ⌘ ⇧ H | กะพริบแพเนลที่โฟกัส |

### เบราว์เซอร์

คีย์ลัดเครื่องมือนักพัฒนาเบราว์เซอร์เป็นไปตามค่าเริ่มต้นของ Safari และปรับแต่งได้ใน `Settings → Keyboard Shortcuts`
คีย์ลัดสำหรับนำทาง command palette รวมถึง ⌃ P ก็ปรับแต่งได้เช่นกัน และสามารถล้างออกได้เพื่อให้การกดแป้นพิมพ์ไปถึงเทอร์มินัลที่ใช้งานอยู่

| คีย์ลัด | การกระทำ |
|----------|--------|
| ⌘ ⇧ L | เปิดเบราว์เซอร์ในการแยก |
| ⌘ L | โฟกัสแถบที่อยู่ |
| ⌘ [ | ย้อนกลับ |
| ⌘ ] | ไปข้างหน้า |
| ⌘ R | โหลดหน้าใหม่ |
| ⌥ ⌘ I | สลับเครื่องมือนักพัฒนา (ค่าเริ่มต้น Safari) |
| ⌥ ⌘ C | แสดง JavaScript Console (ค่าเริ่มต้น Safari) |

### การแจ้งเตือน

| คีย์ลัด | การกระทำ |
|----------|--------|
| ⌘ I | แสดงแผงการแจ้งเตือน |
| ⌘ ⇧ U | กระโดดไปยังรายการที่ยังไม่อ่านล่าสุด |
| ⌥ ⌘ U | สลับสถานะยังไม่อ่านของรายการปัจจุบัน |
| ⌃ ⌘ U | ทำเครื่องหมายรายการปัจจุบันเป็นรายการที่ยังไม่อ่านเก่าที่สุด และกระโดดไปยังรายการที่ยังไม่อ่านล่าสุดถัดไป |

### ค้นหา

| คีย์ลัด | การกระทำ |
|----------|--------|
| ⌘ F | ค้นหา |
| ⌘ ⇧ F | ค้นหาในไดเรกทอรี |
| ⌘ G / ⌥ ⌘ G | ค้นหาถัดไป / ก่อนหน้า |
| ⌥ ⌘ ⇧ F | ซ่อนแถบค้นหา |
| ⌘ E | ใช้สิ่งที่เลือกในการค้นหา |

### เทอร์มินัล

| คีย์ลัด | การกระทำ |
|----------|--------|
| ⌘ K | ล้าง scrollback |
| ⌘ C | คัดลอก (เมื่อมีการเลือก) |
| ⌘ V | วาง |
| ⌘ + / ⌘ - | เพิ่ม / ลดขนาดฟอนต์ |
| ⌘ 0 | รีเซ็ตขนาดฟอนต์ |

### หน้าต่าง

| คีย์ลัด | การกระทำ |
|----------|--------|
| ⌘ ⇧ N | หน้าต่างใหม่ |
| ⌘ ⇧ O | เปิดเซสชันก่อนหน้าอีกครั้ง |
| ⌘ , | การตั้งค่า |
| ⌘ ⇧ , | โหลดการกำหนดค่าใหม่ |
| ⌘ Q | ออก |

## Nightly Builds

[ดาวน์โหลด cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY เป็นแอปแยกต่างหากที่มี bundle ID ของตัวเอง จึงทำงานเคียงข้างเวอร์ชันเสถียรได้ มันถูกสร้างขึ้นโดยอัตโนมัติจาก commit `main` ล่าสุด และอัปเดตอัตโนมัติผ่าน Sparkle feed ของตัวเอง

รายงานบั๊กของ nightly ได้ที่ [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) หรือใน [#nightly-bugs บน Discord](https://discord.gg/xsgFEVrWCZ)

## การกู้คืนเซสชัน

การออกจาก cmux จะบันทึกเซสชันปัจจุบัน เมื่อเปิดใหม่ cmux จะกู้คืนสถานะที่แอปเป็นเจ้าของ:
- เลย์เอาต์หน้าต่าง/พื้นที่ทำงาน/แพเนล
- ไดเรกทอรีทำงาน
- scrollback ของเทอร์มินัล (เท่าที่ทำได้)
- URL และประวัติการนำทางของเบราว์เซอร์

cmux ไม่ทำ checkpoint สถานะกระบวนการที่กำลังทำงานอยู่ตามอำเภอใจ tmux, vim, shell และแอปเทอร์มินัลที่ไม่รองรับจะเปิดใหม่เป็นเทอร์มินัลธรรมดา

เซสชันเอเจนต์ที่รองรับสามารถกลับมาทำงานต่อได้เมื่อ hooks ได้บันทึก native session ID ไว้ ติดตั้ง hooks หลังจากติดตั้ง agent CLI เพื่อให้ไบนารีของมันอยู่บน `PATH`:

```bash
cmux hooks setup
cmux hooks setup codex
cmux hooks setup --agent opencode
```

`cmux hooks setup` จะติดตั้งเอเจนต์ที่รองรับซึ่งมันหาเจอ และพิมพ์สรุปสำหรับเอเจนต์ที่ถูกข้าม การผสานการกู้คืนที่รองรับรวมถึง Claude Code, Codex, Grok, OpenCode, Pi, Amp, Cursor CLI, Gemini, Rovo Dev, Copilot, CodeBuddy, Factory และ Qoder Claude Code จะถูกจัดการโดย cmux Claude wrapper เมื่อมีการเปิดใช้งานการผสาน Claude ในการตั้งค่า

ผู้ใช้ขั้นสูงและการผสานสามารถแนบคำสั่งกู้คืนแบบกำหนดเองเข้ากับพื้นผิวเทอร์มินัลปัจจุบัน ซึ่งมีประโยชน์สำหรับเครื่องมือที่มีสถานะคงทนของตัวเอง เช่น เซสชัน tmux หรือ agent CLI แบบกำหนดเอง:

```bash
cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work
```

การผูกนี้จะยังคงแนบอยู่กับพื้นผิว cmux การผูกที่สร้างผ่าน CLI สาธารณะหรือ socket จะถูกเก็บไว้สำหรับการตรวจสอบและกู้คืนด้วยตนเอง เว้นแต่คุณจะอนุมัติคำนำหน้าคำสั่งที่ลงนามไว้สำหรับการกู้คืนอัตโนมัติ คำนำหน้าที่อนุมัติแล้วยังถูกผูกกับไดเรกทอรีทำงานและค่าสภาพแวดล้อมที่แน่นอนด้วย เมื่อมีอยู่ ตรวจสอบหรือแก้ไขการอนุมัติได้ใน **Settings > Terminal > Resume Commands** cmux จะรันการผูกการกู้คืนเฉพาะที่มันทำเครื่องหมายว่าเชื่อถือได้โดยอัตโนมัติเท่านั้น เช่น การผูก tmux ที่ตรวจพบจากกระบวนการที่กำลังทำงานหรือคำนำหน้าที่ผู้ใช้อนุมัติ คีย์สภาพแวดล้อมที่ละเอียดอ่อน เช่น โทเค็น รหัสผ่าน ความลับ และ API key จะถูกตัดออกก่อนที่จะเก็บการผูกการกู้คืน

เพื่อให้เทอร์มินัลเอเจนต์ที่กู้คืนแล้วอยู่ในสถานะว่างแทนที่จะรันคำสั่งกู้คืนโดยอัตโนมัติ ให้ปิด **Settings > Terminal > Resume Agent Sessions on Reopen** หรือตั้งค่านี้ใน `~/.config/cmux/cmux.json`:

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

นี่จะปิดเฉพาะคำสั่งกู้คืนเอเจนต์อัตโนมัติเท่านั้น cmux ยังคงกู้คืนเลย์เอาต์ที่บันทึกไว้ ไดเรกทอรีทำงาน scrollback และประวัติเบราว์เซอร์

หากคุณต้องการนำสแนปช็อตที่บันทึกล่าสุดมาใช้ใหม่ด้วยตนเอง ให้ใช้:
- `File > Reopen Previous Session`
- `⌘ ⇧ O`
- `cmux restore-session`

เบื้องหลัง cmux จะเขียนสแนปช็อตที่มีการกำกับเวอร์ชันไว้ใต้ `~/Library/Application Support/cmux/` และ agent hooks จะเขียนการแมปเซสชันไว้ใต้ `~/.cmuxterm/` เมื่อกู้คืน cmux จะสร้างเลย์เอาต์ขึ้นใหม่ก่อน จากนั้นจึงรันคำสั่งกู้คืนเนทีฟของเอเจนต์ที่รองรับเมื่อมีการเปิดใช้งานการกู้คืนเอเจนต์อัตโนมัติ

อ่านคู่มือฉบับเต็มได้ที่ <https://cmux.com/docs/session-restore>

## FAQ

### cmux เกี่ยวข้องกับ Ghostty อย่างไร?

cmux ไม่ใช่ fork ของ Ghostty มันใช้ [libghostty](https://github.com/ghostty-org/ghostty) เป็นไลบรารีสำหรับการเรนเดอร์เทอร์มินัล ในแบบเดียวกับที่แอปใช้ WebKit สำหรับมุมมองเว็บ Ghostty เป็นเทอร์มินัลแบบสแตนด์อโลน ส่วน cmux เป็นแอปคนละตัวที่สร้างขึ้นบนเอนจินการเรนเดอร์ของมัน

### รองรับแพลตฟอร์มอะไรบ้าง?

ขณะนี้รองรับเฉพาะ macOS เท่านั้น cmux เป็นแอป Swift + AppKit เนทีฟ

### มีแอป iOS ไหม?

มี อยู่ในช่วงเบต้า จับคู่ iPhone ของคุณกับ Mac จากหน้าต่าง Mobile Connect แล้วเชื่อมต่อเข้ากับเทอร์มินัลของคุณจากโทรศัพท์ พร้อมตัวเลือกในการส่งต่อการแจ้งเตือนของเทอร์มินัล มันเผยแพร่บน TestFlight ในชื่อ cmux BETA ดู [เอกสาร iOS](https://cmux.com/docs/ios)

### cmux ใช้งานได้กับเอเจนต์เขียนโค้ดตัวไหนบ้าง?

ทุกตัว cmux เป็นเทอร์มินัล ดังนั้นเอเจนต์ใด ๆ ที่รันในเทอร์มินัลก็ใช้งานได้ทันที: Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, Goose, Amp, Cline, Cursor Agent และอะไรก็ตามที่คุณสามารถเปิดใช้งานจากบรรทัดคำสั่งได้

### cmux ออร์เคสเตรตเอเจนต์และซับเอเจนต์หลายตัวได้ไหม?

ได้ เมื่อเอเจนต์สร้างซับเอเจนต์หรือเพื่อนร่วมทีม cmux จะเปลี่ยนพวกมันให้เป็นแพเนลและการแยกแบบเนทีฟแทนที่จะเป็นกระบวนการเบื้องหลังที่ซ่อนอยู่ มันรองรับการออร์เคสเตรชันแบบหลายโมเดลของ [Claude Code teams](https://cmux.com/docs/agent-integrations/claude-code-teams) และ [oh-my-opencode](https://cmux.com/docs/agent-integrations/oh-my-opencode) ดังนั้นเอเจนต์ทุกตัวในการรันหนึ่งครั้งจึงมองเห็นและควบคุมได้

### ผมใช้ cmux กับเครื่องระยะไกลได้ไหม?

ได้ เปิดพื้นที่ทำงานผ่าน SSH และเชื่อมต่อเข้ากับเซสชัน tmux ระยะไกล เพื่อให้เอเจนต์รันบนโฮสต์ระยะไกลได้ในขณะที่คุณขับเคลื่อนพวกมันจาก cmux ดู [SSH และระยะไกล](https://cmux.com/docs/ssh)

### การแจ้งเตือนทำงานอย่างไร?

เมื่อกระบวนการต้องการความสนใจ cmux จะแสดงวงแหวนแจ้งเตือนรอบ ๆ แพเนล ป้ายรายการที่ยังไม่อ่านบนแถบด้านข้าง ป๊อปโอเวอร์การแจ้งเตือน และการแจ้งเตือนบนเดสก์ท็อปของ macOS สิ่งเหล่านี้จะทำงานโดยอัตโนมัติผ่าน escape sequence มาตรฐานของเทอร์มินัล (OSC 9/99/777) หรือคุณสามารถเรียกใช้งานได้ด้วย [cmux CLI](https://cmux.com/docs/notifications#cli-usage) และ [agent hooks](https://cmux.com/docs/notifications#integration-examples) เอเจนต์ใด ๆ ที่รองรับ hooks หรือ OSC ก็ใช้งานได้ รวมถึง Claude Code, Codex, OpenCode และ pi

### cmux เขียนโปรแกรมได้ไหม?

ได้ ทุกการกระทำพร้อมใช้งานผ่าน cmux CLI และ Unix socket: สร้างพื้นที่ทำงาน เปิดแพเนลที่แยก ส่งอินพุต อ่านเนื้อหาหน้าจอ ถ่ายภาพหน้าจอ และขับเคลื่อนเบราว์เซอร์ในแอป ดูเอกสาร [CLI reference](https://cmux.com/docs/api) และ [browser automation](https://cmux.com/docs/browser-automation)

### เบราว์เซอร์ในตัวทำอะไรได้บ้าง?

cmux สามารถแยกแพเนลเบราว์เซอร์จริงไว้ข้างเทอร์มินัลของคุณ และมันเขียนโปรแกรมได้อย่างเต็มที่: นำทาง ถ่ายสแนปช็อต DOM คลิก พิมพ์ ประเมิน JavaScript และอ่านกิจกรรมของคอนโซลและเครือข่ายผ่าน socket API เดียวกัน เอเจนต์ใช้มันเพื่อยืนยันการเปลี่ยนแปลงเว็บของตัวเองโดยไม่ต้องออกจาก cmux ดู [browser automation](https://cmux.com/docs/browser-automation)

### cmux มี skills ไหม?

มี Skills คือเวิร์กโฟลว์ที่นำกลับมาใช้ใหม่ได้ ซึ่งคุณสามารถมอบให้เอเจนต์ใด ๆ ที่รันใน cmux สำหรับสิ่งต่าง ๆ เช่น การควบคุม CLI การทำพื้นที่ทำงานอัตโนมัติ การตั้งค่า และพื้นผิวเบราว์เซอร์ เลือกดูคอลเลกชันแบบเปิดได้ที่ [cmux-skills](https://github.com/manaflow-ai/cmux-skills) หรืออ่าน [เอกสาร skills](https://cmux.com/docs/skills)

### ผมปรับแต่งคีย์ลัดได้ไหม?

การผูกแป้นพิมพ์ของเทอร์มินัลถูกอ่านจากไฟล์การกำหนดค่า Ghostty ของคุณ (`~/.config/ghostty/config`) คีย์ลัดเฉพาะของ cmux (พื้นที่ทำงาน การแยก เบราว์เซอร์ การแจ้งเตือน) ปรับแต่งได้ในการตั้งค่า ดู [คีย์ลัดเริ่มต้น](https://cmux.com/docs/keyboard-shortcuts) สำหรับรายการทั้งหมด

### ผมปรับแต่ง cmux ได้ไหม?

ได้ การเรนเดอร์เทอร์มินัลใช้การกำหนดค่า Ghostty ของคุณ ดังนั้นธีม ฟอนต์ สี และเคอร์เซอร์จะถูกนำมาใช้โดยตรง การตั้งค่าของ cmux เองใน `~/.config/cmux/cmux.json` ควบคุมแถบด้านข้าง แถบแท็บ แพเนลที่แยก และพฤติกรรม และทุก [คีย์ลัด](https://cmux.com/docs/keyboard-shortcuts) แก้ไขได้ ดู [การกำหนดค่า](https://cmux.com/docs/configuration)

### เซสชันของผมถูกบันทึกไหม?

ใช่ cmux จะกู้คืนหน้าต่าง พื้นที่ทำงาน แพเนล ไดเรกทอรีทำงาน และ scrollback ของคุณเมื่อคุณเปิดใหม่ และสถานะจะอยู่รอดได้แม้รีสตาร์ตเครื่องคอมพิวเตอร์เต็มรูปแบบ ไม่ใช่แค่ออกจากแอป เซสชันเอเจนต์อย่าง Claude Code, Codex และ OpenCode ก็กลับมาด้วย ดู [การกู้คืนเซสชัน](https://cmux.com/docs/session-restore)

### มันเทียบกับ tmux อย่างไร?

tmux เป็น terminal multiplexer ที่รันอยู่ภายในเทอร์มินัลใดก็ได้ ส่วน cmux เป็นแอป macOS เนทีฟพร้อม GUI: แท็บแนวตั้ง แพเนลที่แยก เบราว์เซอร์ฝังตัว และ socket API ทั้งหมดมีในตัว ไม่ต้องใช้ไฟล์การกำหนดค่าหรือ prefix key อย่างไรก็ตาม หลายคนยินดีที่จะรัน cmux ร่วมกับ SSH และ tmux และ cmux สามารถเชื่อมต่อเข้ากับเซสชัน tmux ระยะไกลของคุณได้แบบเนทีฟ ([เบต้า](https://cmux.com/docs/remote-tmux))

### cmux ฟรีไหม?

ใช่ cmux ใช้งานได้ฟรี ซอร์สโค้ดมีให้บน [GitHub](https://github.com/manaflow-ai/cmux)

### ผมจะสนับสนุน cmux ได้อย่างไร?

cmux ฟรีและโอเพนซอร์ส และจะเป็นเช่นนั้นเสมอ หากคุณต้องการสนับสนุนการพัฒนาและรับการเข้าถึงสิ่งที่กำลังจะมาก่อนใคร รวมถึง cmux AI, แอป iOS และ Cloud VMs ลองดู [cmux Founders Edition](https://github.com/manaflow-ai/cmux#founders-edition)

### ผมมีคำขอฟีเจอร์หรือพบบั๊ก?

เราอยากได้ยิน เปิด [issue](https://github.com/manaflow-ai/cmux/issues) หรือ [pull request](https://github.com/manaflow-ai/cmux/pulls) บน GitHub หรือ [อีเมลหาเรา](mailto:founders@manaflow.com?subject=cmux%20feature%20request)

## Star History

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## การมีส่วนร่วม

วิธีเข้าร่วม:

- ติดตามเราบน X เพื่อรับข่าวสาร [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen) และ [@austinywang](https://x.com/austinywang)
- เข้าร่วมการสนทนาบน [Discord](https://discord.gg/xsgFEVrWCZ)
- สร้างและเข้าร่วมใน [GitHub issues](https://github.com/manaflow-ai/cmux/issues) และ [discussions](https://github.com/manaflow-ai/cmux/discussions)
- บอกเราว่าคุณกำลังสร้างอะไรด้วย cmux

## ชุมชน

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

<p>
  <strong>WeChat:</strong> สแกนคิวอาร์โค้ดเพื่อเข้าร่วมชุมชน<br />
  <img src="./docs/assets/wechat-community-qr.jpg" alt="คิวอาร์โค้ด WeChat สำหรับเข้าร่วมชุมชน cmux" width="240" />
</p>

## Founder's Edition

cmux ฟรี โอเพนซอร์ส และจะเป็นเช่นนั้นเสมอ หากคุณต้องการสนับสนุนการพัฒนาและรับการเข้าถึงสิ่งที่กำลังจะมาก่อนใคร:

**[รับ Founder's Edition](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **คำขอฟีเจอร์/การแก้บั๊กที่ได้รับการจัดลำดับความสำคัญ**
- **เข้าถึงก่อนใคร: cmux AI ที่ให้บริบทเกี่ยวกับทุกพื้นที่ทำงาน แท็บ และแผง**
- **เข้าถึงก่อนใคร: แอป iOS ที่ซิงค์เทอร์มินัลระหว่างเดสก์ท็อปและโทรศัพท์**
- **เข้าถึงก่อนใคร: Cloud VMs**
- **เข้าถึงก่อนใคร: โหมดเสียง**
- **iMessage/WhatsApp ส่วนตัวของผม**

## สัญญาอนุญาต

cmux เป็นโอเพนซอร์สภายใต้ [GPL-3.0-or-later](LICENSE)

หากองค์กรของคุณไม่สามารถปฏิบัติตาม GPL ได้ มีสัญญาอนุญาตเชิงพาณิชย์ให้บริการ ติดต่อ [founders@manaflow.com](mailto:founders@manaflow.com) สำหรับรายละเอียด
