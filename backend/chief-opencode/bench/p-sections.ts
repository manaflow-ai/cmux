// Dumps the P brain's fixed request sections (system prompt and tool definitions) as JSON, for the
// P vs O token diff. Run on a VM from backend/apps/api: bun ../../chief-opencode/bench/p-sections.ts
import { systemPrompt } from "../../apps/api/src/chief-brain/prompts.ts"
import { memoryTools } from "../../apps/api/src/chief-brain/brain-tools.ts"
import { chiefsTools } from "../../apps/api/src/chief-brain/brain-chiefs.ts"
import { handsTools } from "../../apps/api/src/chief-brain/brain-hands.ts"

const profile = { display_name: "Compare P", role: "", personality: "", instructions: "" }
const env = {} as never
const tools = [...memoryTools(() => null as never), ...chiefsTools(env, () => ({ agent: null, owner: null }) as never), ...handsTools(env, () => ({ agent: null, owner: null }))]
console.log(JSON.stringify({ system: systemPrompt(profile), tools: tools.map((t) => ({ name: t.name, description: t.description, input_schema: JSON.parse(JSON.stringify(t.parameters)) })) }))
