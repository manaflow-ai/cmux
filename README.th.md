> การแปลนี้สร้างโดย Claude หากมีข้อเสนอแนะในการปรับปรุง กรุณาเปิด PR

<h1 align="center">cmux</h1>
<p align="center">เทอร์มินัล macOS ที่ใช้ Ghostty พร้อมแท็บแนวตั้งและการแจ้งเตือนสำหรับเอเจนต์เขียนโค้ด AI</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="ดาวน์โหลด cmux สำหรับ macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | ไทย | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
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
แผงจะมีวงแหวนสีน้ำเงินและแท็บจะสว่างขึ้นเมื่อเอเจนต์เขียนโค้ดต้องการความสนใจของคุณ
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="วงแหวนแจ้งเตือน" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>แผงแจ้งเตือน</h3>
ดูการแจ้งเตือนที่รอดำเนินการทั้งหมดในที่เดียว ข้ามไปยังรายการที่ยังไม่ได้อ่านล่าสุด
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="ป้ายแจ้งเตือนแถบด้านข้าง" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>เบราว์เซอร์ในแอป</h3>
แบ่งเบราว์เซอร์ข้างเทอร์มินัลพร้อม API ที่เขียนสคริปต์ได้ ย้ายมาจาก <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="เบราว์เซอร์ในตัว" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>แท็บแนวตั้ง + แนวนอน</h3>
แถบด้านข้างแสดง git branch, สถานะ/หมายเลข PR ที่เชื่อมโยง, ไดเรกทอรีทำงาน, พอร์ตที่กำลังฟัง และข้อความแจ้งเตือนล่าสุด แบ่งแนวนอนและแนวตั้ง
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="แท็บแนวตั้งและแผงแบ่ง" width="100%" />
</td>
</tr>
</table>

- **เขียนสคริปต์ได้** — CLI และ socket API สำหรับสร้างเวิร์กสเปซ แบ่งแผง ส่งการกดแป้นพิมพ์ และควบคุมเบราว์เซอร์อัตโนมัติ
- **แอป macOS ดั้งเดิม** — สร้างด้วย Swift และ AppKit ไม่ใช่ Electron เริ่มต้นเร็ว ใช้หน่วยความจำน้อย
- **เข้ากันได้กับ Ghostty** — อ่านการตั้งค่าที่มีอยู่ของคุณจาก `~/.config/ghostty/config` สำหรับธีม ฟอนต์ และสี
- **เร่งความเร็วด้วย GPU** — ขับเคลื่อนโดย libghostty สำหรับการแสดงผลที่ลื่นไหล

## การติดตั้ง

### DMG (แนะนำ)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="ดาวน์โหลด cmux สำหรับ macOS" width="180" />
</a>

เปิดไฟล์ `.dmg` แล้วลาก cmux ไปยังโฟลเดอร์แอปพลิเคชัน cmux อัปเดตอัตโนมัติผ่าน Sparkle คุณจึงต้องดาวน์โหลดเพียงครั้งเดียว

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

สำหรับอัปเดตในภายหลัง:

```bash
brew upgrade --cask cmux
```

เมื่อเปิดใช้งานครั้งแรก macOS อาจขอให้คุณยืนยันการเปิดแอปจากนักพัฒนาที่ได้รับการระบุตัวตน คลิก **เปิด** เพื่อดำเนินการต่อ

## ทำไมต้อง cmux?

ผมรันเซสชัน Claude Code และ Codex จำนวนมากพร้อมกัน ผมใช้ Ghostty กับแผงแบ่งหลายอัน และพึ่งพาการแจ้งเตือนดั้งเดิมของ macOS เพื่อรู้ว่าเมื่อไหร่ที่เอเจนต์ต้องการผม แต่ข้อความแจ้งเตือนของ Claude Code มีแค่ "Claude is waiting for your input" โดยไม่มีบริบท และเมื่อเปิดแท็บมากพอ ผมไม่สามารถอ่านชื่อแท็บได้เลย

ผมลองใช้ออร์เคสเตรเตอร์สำหรับเขียนโค้ดบางตัว แต่ส่วนใหญ่เป็นแอป Electron/Tauri และประสิทธิภาพทำให้ผมรำคาญ ผมยังชอบเทอร์มินัลมากกว่าเพราะออร์เคสเตรเตอร์ GUI บังคับให้คุณใช้เวิร์กโฟลว์ของมัน ผมจึงสร้าง cmux เป็นแอป macOS ดั้งเดิมด้วย Swift/AppKit มันใช้ libghostty สำหรับการแสดงผลเทอร์มินัลและอ่านการตั้งค่า Ghostty ที่มีอยู่ของคุณสำหรับธีม ฟอนต์ และสี

สิ่งที่เพิ่มเติมหลักคือแถบด้านข้างและระบบแจ้งเตือน แถบด้านข้างมีแท็บแนวตั้งที่แสดง git branch, สถานะ/หมายเลข PR ที่เชื่อมโยง, ไดเรกทอรีทำงาน, พอร์ตที่กำลังฟัง และข้อความแจ้งเตือนล่าสุดสำหรับแต่ละเวิร์กสเปซ ระบบแจ้งเตือนจับลำดับเทอร์มินัล (OSC 9/99/777) และมี CLI (`cmux notify`) ที่คุณสามารถเชื่อมต่อกับ hook ของเอเจนต์สำหรับ Claude Code, OpenCode เป็นต้น เมื่อเอเจนต์กำลังรอ แผงของมันจะมีวงแหวนสีน้ำเงินและแท็บจะสว่างขึ้นในแถบด้านข้าง เพื่อให้ผมบอกได้ว่าอันไหนต้องการผมข้ามแผงแบ่งและแท็บต่าง ๆ Cmd+Shift+U ข้ามไปยังรายการที่ยังไม่ได้อ่านล่าสุด

เบราว์เซอร์ในแอปมี API ที่เขียนสคริปต์ได้ ย้ายมาจาก [agent-browser](https://github.com/vercel-labs/agent-browser) เอเจนต์สามารถจับภาพ accessibility tree, รับ element refs, คลิก, กรอกฟอร์ม และรัน JS ได้ คุณสามารถแบ่งแผงเบราว์เซอร์ข้างเทอร์มินัลและให้ Claude Code โต้ตอบกับเซิร์ฟเวอร์สำหรับพัฒนาของคุณโดยตรง

ทุกอย่างเขียนสคริปต์ได้ผ่าน CLI และ socket API — สร้างเวิร์กสเปซ/แท็บ แบ่งแผง ส่งการกดแป้นพิมพ์ เปิด URL ในเบราว์เซอร์

## The Zen of cmux

cmux ไม่ได้กำหนดว่านักพัฒนาต้องใช้เครื่องมืออย่างไร มันเป็นเทอร์มินัลและเบราว์เซอร์พร้อม CLI ส่วนที่เหลือขึ้นอยู่กับคุณ

cmux เป็นส่วนประกอบพื้นฐาน ไม่ใช่โซลูชันสำเร็จรูป มันให้เทอร์มินัล เบราว์เซอร์ การแจ้งเตือน เวิร์กสเปซ แผงแบ่ง แท็บ และ CLI เพื่อควบคุมทั้งหมด cmux ไม่บังคับให้คุณใช้เอเจนต์เขียนโค้ดในแบบที่มีความคิดเห็นตายตัว สิ่งที่คุณสร้างด้วยส่วนประกอบพื้นฐานเหล่านี้เป็นของคุณ

นักพัฒนาที่ดีที่สุดสร้างเครื่องมือของตัวเองมาตลอด ยังไม่มีใครหาวิธีทำงานกับเอเจนต์ที่ดีที่สุด และทีมที่สร้างผลิตภัณฑ์แบบปิดก็ยังไม่ได้หาเช่นกัน นักพัฒนาที่อยู่ใกล้โค้ดเบสของตัวเองมากที่สุดจะเป็นคนหาคำตอบก่อน

ให้ส่วนประกอบพื้นฐานที่ประกอบกันได้แก่นักพัฒนาล้านคน แล้วพวกเขาจะร่วมกันค้นพบเวิร์กโฟลว์ที่มีประสิทธิภาพที่สุดได้เร็วกว่าทีมผลิตภัณฑ์ใดจะออกแบบจากบนลงล่าง

## เอกสารประกอบ

สำหรับข้อมูลเพิ่มเติมเกี่ยวกับการตั้งค่า cmux, [ไปที่เอกสารของเรา](https://cmux.com/docs/getting-started?utm_source=readme)

## ปุ่มลัด

### เวิร์กสเปซ

| ปุ่มลัด | การทำงาน |
|----------|--------|
| ⌘ N | เวิร์กสเปซใหม่ |
| ⌘ 1–8 | ข้ามไปเวิร์กสเปซ 1–8 |
| ⌘ 9 | ข้ามไปเวิร์กสเปซสุดท้าย |
| ⌃ ⌘ ] | เวิร์กสเปซถัดไป |
| ⌃ ⌘ [ | เวิร์กสเปซก่อนหน้า |
| ⌘ ⇧ W | ปิดเวิร์กสเปซ |
| ⌘ ⇧ R | เปลี่ยนชื่อเวิร์กสเปซ |
| ⌘ B | สลับแถบด้านข้าง |

### เซอร์เฟซ

| ปุ่มลัด | การทำงาน |
|----------|--------|
| ⌘ T | เซอร์เฟซใหม่ |
| ⌘ ⇧ ] | เซอร์เฟซถัดไป |
| ⌘ ⇧ [ | เซอร์เฟซก่อนหน้า |
| ⌃ Tab | เซอร์เฟซถัดไป |
| ⌃ ⇧ Tab | เซอร์เฟซก่อนหน้า |
| ⌃ 1–8 | ข้ามไปเซอร์เฟซ 1–8 |
| ⌃ 9 | ข้ามไปเซอร์เฟซสุดท้าย |
| ⌘ W | ปิดเซอร์เฟซ |

### แผงแบ่ง

| ปุ่มลัด | การทำงาน |
|----------|--------|
| ⌘ D | แบ่งไปทางขวา |
| ⌘ ⇧ D | แบ่งลงล่าง |
| ⌥ ⌘ ← → ↑ ↓ | โฟกัสแผงตามทิศทาง |
| ⌘ ⇧ H | กะพริบแผงที่โฟกัส |

### เบราว์เซอร์

ปุ่มลัดเครื่องมือสำหรับนักพัฒนาของเบราว์เซอร์ใช้ค่าเริ่มต้นของ Safari และสามารถปรับแต่งได้ใน `Settings → Keyboard Shortcuts`

| ปุ่มลัด | การทำงาน |
|----------|--------|
| ⌘ ⇧ L | เปิดเบราว์เซอร์ในแผงแบ่ง |
| ⌘ L | โฟกัสแถบที่อยู่ |
| ⌘ [ | ย้อนกลับ |
| ⌘ ] | ไปข้างหน้า |
| ⌘ R | โหลดหน้าใหม่ |
| ⌥ ⌘ I | เปิด/ปิดเครื่องมือสำหรับนักพัฒนา (ค่าเริ่มต้น Safari) |
| ⌥ ⌘ C | แสดง JavaScript Console (ค่าเริ่มต้น Safari) |

### การแจ้งเตือน

| ปุ่มลัด | การทำงาน |
|----------|--------|
| ⌘ I | แสดงแผงแจ้งเตือน |
| ⌘ ⇧ U | ข้ามไปยังรายการที่ยังไม่ได้อ่านล่าสุด |

### ค้นหา

| ปุ่มลัด | การทำงาน |
|----------|--------|
| ⌘ F | ค้นหา |
| ⌘ G / ⌘ ⇧ G | ค้นหาถัดไป / ก่อนหน้า |
| ⌘ ⇧ F | ซ่อนแถบค้นหา |
| ⌘ E | ใช้ส่วนที่เลือกสำหรับค้นหา |

### เทอร์มินัล

| ปุ่มลัด | การทำงาน |
|----------|--------|
| ⌘ K | ล้างประวัติการเลื่อน |
| ⌘ C | คัดลอก (เมื่อเลือกข้อความ) |
| ⌘ V | วาง |
| ⌘ + / ⌘ - | เพิ่ม / ลดขนาดฟอนต์ |
| ⌘ 0 | รีเซ็ตขนาดฟอนต์ |

### หน้าต่าง

| ปุ่มลัด | การทำงาน |
|----------|--------|
| ⌘ ⇧ N | หน้าต่างใหม่ |
| ⌘ , | การตั้งค่า |
| ⌘ ⇧ , | โหลดการตั้งค่าใหม่ |
| ⌘ Q | ออก |

## บิลด์ Nightly

[ดาวน์โหลด cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY เป็นแอปแยกต่างหากที่มี bundle ID เป็นของตัวเอง จึงสามารถรันควบคู่กับเวอร์ชันเสถียรได้ สร้างอัตโนมัติจากคอมมิต `main` ล่าสุดและอัปเดตอัตโนมัติผ่านฟีด Sparkle ของตัวเอง

## การกู้คืนเซสชัน (พฤติกรรมปัจจุบัน)

เมื่อเปิดใหม่ cmux จะกู้คืนเลย์เอาต์และข้อมูลเมตาของแอปเท่านั้น:
- เลย์เอาต์หน้าต่าง/เวิร์กสเปซ/แผง
- ไดเรกทอรีทำงาน
- ประวัติการเลื่อนของเทอร์มินัล (พยายามอย่างดีที่สุด)
- URL ของเบราว์เซอร์และประวัติการนำทาง

cmux **ไม่**กู้คืนสถานะกระบวนการที่กำลังทำงานภายในแอปเทอร์มินัล ตัวอย่างเช่น เซสชัน Claude Code/tmux/vim ที่กำลังทำงานอยู่จะยังไม่ถูกกู้คืนหลังจากรีสตาร์ท

## ประวัติดาว

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## การมีส่วนร่วม

วิธีเข้าร่วม:

- ติดตามเราบน X สำหรับข่าวสาร [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen) และ [@austinywang](https://x.com/austinywang)
- เข้าร่วมสนทนาบน [Discord](https://discord.gg/xsgFEVrWCZ)
- สร้างและมีส่วนร่วมใน [GitHub issues](https://github.com/manaflow-ai/cmux/issues) และ [discussions](https://github.com/manaflow-ai/cmux/discussions)
- แจ้งให้เรารู้ว่าคุณกำลังสร้างอะไรด้วย cmux

## ชุมชน

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Founder's Edition

cmux เป็นซอฟต์แวร์ฟรี โอเพนซอร์ส และจะเป็นเช่นนั้นตลอดไป หากคุณต้องการสนับสนุนการพัฒนาและเข้าถึงสิ่งที่กำลังจะมาถึงก่อนใคร:

**[รับ Founder's Edition](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **คำขอฟีเจอร์/แก้ไขบั๊กที่ได้รับความสำคัญ**
- **เข้าถึงก่อน: cmux AI ที่ให้บริบทเกี่ยวกับทุกเวิร์กสเปซ แท็บ และแผง**
- **เข้าถึงก่อน: แอป iOS ที่ซิงค์เทอร์มินัลระหว่างเดสก์ท็อปและโทรศัพท์**
- **เข้าถึงก่อน: Cloud VMs**
- **เข้าถึงก่อน: โหมดเสียง**
- **iMessage/WhatsApp ส่วนตัวของผม**

## สัญญาอนุญาต

cmux เป็นโอเพนซอร์สภายใต้ [AGPL-3.0-or-later](LICENSE)

หากองค์กรของคุณไม่สามารถปฏิบัติตาม AGPL ได้ มีสัญญาอนุญาตเชิงพาณิชย์ให้เลือกใช้ ติดต่อ [founders@manaflow.com](mailto:founders@manaflow.com) สำหรับรายละเอียด
