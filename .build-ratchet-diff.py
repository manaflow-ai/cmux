import collections,importlib.util,os,sys
head,base,hroot,broot=sys.argv[1:5]
spec=importlib.util.spec_from_file_location("r",os.path.join(hroot,"scripts/cmux-next/rust_panic_ratchet.py"))
r=importlib.util.module_from_spec(spec); spec.loader.exec_module(r)
def keyed(path,root):
    _,counts,_,_,hits=r.read_clippy(path)
    out=collections.Counter()
    for (crate,lint),locs in hits.items():
        if crate!="acpmux" or lint not in("indexing_slicing","string_slice"): continue
        for loc in locs:
            f,ln,_=loc.rsplit(":",2)
            p=f if os.path.isabs(f) else os.path.join(root,"cmux-tui",f)
            try: t=open(p).read().splitlines()[int(ln)-1].strip()
            except Exception: t="?"
            out[(lint,f.split("cmux-tui/",1)[-1],t)]+=1
    print(path,{l:c for l,c in counts["acpmux"].items() if l in("indexing_slicing","string_slice")})
    return out
h=keyed(head,hroot); b=keyed(base,broot)
for k in sorted(h):
    if h[k]>b.get(k,0): print("NEW",h[k]-b.get(k,0),*k,sep="\t")
