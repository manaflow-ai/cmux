import { chromium } from 'playwright';
import { readFile } from 'node:fs/promises';
const root='/home/cmux/.wt/checkouts/cmux/lane--intro-walk-four-screens-carry/webviews/dist/gallery';
const out='/home/cmux/.wt/checkouts/cmux/lane--intro-setups-data/capture-scratch/walk-captures-16bf471';
const contentTypes:any={'.html':'text/html','.js':'text/javascript','.mjs':'text/javascript','.css':'text/css','.json':'application/json','.svg':'image/svg+xml','.png':'image/png','.woff':'font/woff','.woff2':'font/woff2'};
const server=Bun.serve({port:0,async fetch(req){const u=new URL(req.url);const p=decodeURIComponent(u.pathname).replace(/^\/+/, '')||'index.html'; try{return new Response(await readFile(`${root}/${p}`),{headers:{'content-type':contentTypes[p.slice(p.lastIndexOf('.'))]??'application/octet-stream'}})}catch{return new Response('not found',{status:404})}}});
const browser=await chromium.launch({headless:true, executablePath:process.env.CMUX_CHROME_HEADLESS_SHELL});
for (const variant of ['look','work','trust','tune']) {
  const page=await browser.newPage({viewport:{width:640,height:620}, deviceScaleFactor:2, colorScheme:'light'});
  const errors:string[]=[]; page.on('pageerror',e=>errors.push(e.stack||e.message)); page.on('console',m=>{if(m.type()==='error') errors.push(m.text())});
  const url=`http://127.0.0.1:${server.port}/frame.html?entry=pages.onboarding&variant=intro-walk-${variant}&locale=en&theme=Apple%20System%20Colors%20Light`;
  await page.goto(url,{waitUntil:'domcontentloaded'});
  await page.locator(`.onb-make[data-screen="${variant}"]`).waitFor({state:'visible',timeout:10000});
  await page.waitForFunction(()=>document.documentElement.dataset.galleryReady==='1');
  await page.screenshot({path:`${out}/intro-walk-${variant}-16bf471-light.png`,fullPage:true});
  console.log(variant, 'ready', await page.locator('html').getAttribute('data-gallery-ready'), 'heading', await page.locator('.onb-title').innerText(), 'errors', errors.length);
  if(errors.length) console.log(errors.join('\n'));
  await page.close();
}
await browser.close(); server.stop();
