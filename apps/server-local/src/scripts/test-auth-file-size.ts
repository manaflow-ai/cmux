#!/usr/bin/env tsx
import * as fs from 'fs/promises';
import * as os from 'os';

async function main() {
  const homeDir = os.homedir();
  const claudeJsonPath = `${homeDir}/.claude.json`;
  
  try {
    const stats = await fs.stat(claudeJsonPath);
    console.log(`File size: ${stats.size} bytes (${(stats.size / 1024 / 1024).toFixed(2)} MB)`);
    
    const content = await fs.readFile(claudeJsonPath, 'utf8');
    console.log(`Content length: ${content.length} characters`);
    
    // Check if it's valid JSON
    try {
      const parsed = JSON.parse(content);
      console.log(`Valid JSON with keys:`, Object.keys(parsed));
      
      // Check the size when base64 encoded (as it's sent)
      const base64Size = Buffer.from(content).toString('base64').length;
      console.log(`Base64 encoded size: ${base64Size} bytes (${(base64Size / 1024 / 1024).toFixed(2)} MB)`);
    } catch (e) {
      console.error(`Invalid JSON:`, e);
    }
  } catch (error) {
    console.error(`Error reading file:`, error);
  }
}

main().catch(console.error);